<#
.SYNOPSIS
    Plans exact-target role additions owned by an already deployed Primary.
.DESCRIPTION
    The handler runs in Windows PowerShell 5.1, on its owning Primary, with the
    ConfigMgr provider already connected. It needs only function definitions from
    ScriptFunctions.ps1, not a ScriptWorkflow run or any existing workflow files.
    Completed requires native role/site readiness, not just setup submission.
    Existing prerequisites are observed, never repaired. No handler wait depends
    on a requested node's final Phase 8 or ScriptWorkflow completion receipt.
    SMSProvider targets are verification-only: native provider addition performs
    broader site maintenance and is prohibited by the preservation policy.
    New passive computer bindings may be provisioned on healthy dependencies;
    existing principals, denied access, service/trust faults are never repaired.
    Library relocation reserves an empty destination and observes native cutover;
    native copying can temporarily pause the site's package processing.
#>
function Get-MemLabsExistingRoleActions {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$DeployConfig)

    $groups = @{}
    $names = @{}
    foreach ($vm in @(Get-MemLabsRequestedDeploymentVMs -DeployConfig $DeployConfig)) {
        if ($null -eq $vm) { continue }
        $roleFlags = $vm.installDP -eq $true -or $vm.installMP -eq $true -or
            $vm.installSUP -eq $true -or $vm.installRP -eq $true -or $vm.installSMSProv -eq $true
        $isRoleTarget = $vm.role -in @('SiteSystem', 'Secondary', 'PassiveSite') -or $roleFlags
        if (-not $isRoleTarget -or $vm.role -in @('Primary', 'CAS') -or
            (Test-MemLabsContextOnlyVM -VM $vm)) { continue }
        if (-not $vm.vmName -or "$($vm.vmName)" -notmatch '^[a-zA-Z0-9][a-zA-Z0-9-]*$') {
            throw "A requested site-role target has an invalid VM name '$($vm.vmName)'."
        }
        $effectiveSiteCode = "$($vm.siteCode)"
        if (-not $effectiveSiteCode -and ($vm.installRP -eq $true -or $vm.installSMSProv -eq $true) -and
            $vm.installDP -ne $true -and $vm.installMP -ne $true -and $vm.installSUP -ne $true) {
            $sqlOwners = @($DeployConfig.virtualMachines | Where-Object {
                    $_ -and $_.role -in @('Primary', 'CAS') -and $_.remoteSQLVM -ieq $vm.vmName
                })
            if ($sqlOwners.Count -ne 1) { throw "Cannot resolve one remote-SQL role owner for requested '$($vm.vmName)'." }
            $effectiveSiteCode = "$($sqlOwners[0].siteCode)"
        }
        if ($effectiveSiteCode -notmatch '^[a-zA-Z0-9]{3}$') {
            throw "Requested site-role target '$($vm.vmName)' needs an explicit three-character site code."
        }
        if ($vm.enablePullDP -eq $true -and $vm.installDP -ne $true) {
            throw "Requested pull DP '$($vm.vmName)' must also request installDP."
        }
        if ($names.ContainsKey("$($vm.vmName)")) { throw "Duplicate requested site-role target '$($vm.vmName)'." }
        $names["$($vm.vmName)"] = $true
        $targetMatches = @($DeployConfig.virtualMachines | Where-Object { $_ -and $_.vmName -ieq $vm.vmName })
        if ($targetMatches.Count -ne 1) { throw "Cannot uniquely resolve requested site-role VM '$($vm.vmName)'." }

        $directOwners = @($DeployConfig.virtualMachines | Where-Object { $_ -and $_.role -in @('Primary', 'CAS') -and $_.siteCode -eq $effectiveSiteCode })
        if ($directOwners.Count -gt 1) { throw "Requested role '$($vm.vmName)' has ambiguous site ownership." }
        if ($directOwners.Count -eq 1 -and -not (Test-MemLabsContextOnlyVM -VM $directOwners[0])) { continue }
        $owner = Resolve-MemLabsDeploymentPrimary -DeployConfig $DeployConfig -SiteCode $effectiveSiteCode
        if (-not $owner -or $owner.role -ne 'Primary') {
            throw "No unique owning Primary was resolved for '$($vm.vmName)' (site $($vm.siteCode))."
        }
        if (-not (Test-MemLabsContextOnlyVM -VM $owner)) { continue }
        $key = "$($owner.vmName)"
        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = [pscustomobject]@{ Owner = $owner; Targets = [Collections.Generic.List[object]]::new() }
        }
        $target = [ordered]@{}
        foreach ($property in @('vmName', 'role', 'siteCode', 'parentSiteCode', 'siteName',
                'pullDPSourceDP', 'remoteContentLibVM', 'cmInstallDir', 'sqlVersion', 'sqlInstanceName', 'sqlPort')) {
            $target[$property] = "$($vm.$property)"
        }
        $target.ConfiguredSiteCode = "$($vm.siteCode)"
        $target.siteCode = $effectiveSiteCode
        $target.IsNewTarget = -not $vm.hidden -and $vm.ExistingVM -ne $true
        foreach ($property in @('installDP', 'enablePullDP', 'installMP', 'installSUP', 'installRP', 'installSMSProv')) {
            $target[$property] = $vm.$property -eq $true
        }
        $groups[$key].Targets.Add([pscustomobject]$target)
    }

    $handler = {
        param($Payload)

        $ErrorActionPreference = 'Stop'
        if ($Payload -is [string]) { $Payload = ConvertFrom-Json -InputObject $Payload -ErrorAction Stop }
        if (-not $Payload -or $Payload.Version -ne 1 -or -not $Payload.Targets -or
            "$($Payload.SiteCode)" -notmatch '^[a-zA-Z0-9]{3}$' -or
            "$($Payload.OwnerVMName)" -notmatch '^[a-zA-Z0-9][a-zA-Z0-9-]*$') {
            throw 'Invalid existing-hierarchy SiteRoles payload.'
        }
        if ($ThisVM.role -ne 'Primary' -or $ThisVM.vmName -ine $Payload.OwnerVMName -or
            $ThisVM.siteCode -ine $Payload.SiteCode -or $SiteCode -ine $Payload.SiteCode -or
            "$env:COMPUTERNAME" -ine "$($Payload.OwnerVMName)" -or
            (Get-Location).Drive.Name -ine $Payload.SiteCode) {
            throw "SiteRoles owner/provider mismatch: expected Primary '$($Payload.OwnerVMName)' on CMSite '$($Payload.SiteCode)'."
        }
        $actionDeadline = (Get-Date).AddSeconds(7000)

        function Assert-ScopedBudget {
            if ((Get-Date) -ge $actionDeadline) { throw 'SiteRoles action reached its bounded deadline; no further changes were submitted.' }
        }

        function Get-ScopedFqdn {
            param([string]$Name)
            if (-not $Name -or $Name.Trim() -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]*$') { throw "Invalid required computer name '$Name'." }
            if ($Name -like '*.*') { return $Name.Trim().TrimEnd('.') }
            return "$($Name.Trim()).$DomainFullName"
        }

        function Get-ScopedConfigVM {
            param([string]$Name)
            $found = @($deployConfig.virtualMachines | Where-Object { $_ -and $_.vmName -ieq $Name })
            if ($found.Count -ne 1) { throw "Required VM '$Name' has $($found.Count) entries in deployConfig." }
            return $found[0]
        }

        function Get-ScopedSite {
            param([string]$Code, [switch]$AllowMissing)
            $rows = @(Get-CMSite -SiteCode $Code -ErrorAction Stop | Where-Object { $null -ne $_ })
            if ($rows.Count -eq 0 -and $AllowMissing) { return $null }
            if ($rows.Count -ne 1) { throw "Required site '$Code' has $($rows.Count) provider rows; no repair was attempted." }
            return $rows[0]
        }

        function Wait-ScopedObservation {
            param(
                [scriptblock]$Probe, [string]$Description, [int]$Seconds = 1800,
                [switch]$RetryReadErrors, [int]$ConsecutiveSuccesses = 1
            )
            $deadline = (Get-Date).AddSeconds($Seconds)
            if ($deadline -gt $actionDeadline) { $deadline = $actionDeadline }
            $detail = 'no ready observation'
            $successes = 0
            do {
                Assert-ScopedBudget
                try { $state = & $Probe }
                catch {
                    if (-not $RetryReadErrors -or $_.Exception -is [Management.Automation.CommandNotFoundException] -or
                        $_.Exception -is [Management.Automation.ParameterBindingException]) { throw }
                    $state = [pscustomobject]@{ Ready = $false; Detail = $_.Exception.Message }
                }
                if ($state -and $state.Ready -eq $true) {
                    $successes++
                    if ($successes -ge $ConsecutiveSuccesses) { return $state }
                }
                else { $successes = 0 }
                if ($state -and $state.Detail) { $detail = "$($state.Detail)" }
                if ((Get-Date) -ge $deadline) { break }
                Write-DscStatus "Waiting for requested target: $Description ($detail)." -RetrySeconds 15
                Start-Sleep -Seconds 15
            } while ((Get-Date) -lt $deadline)
            throw "Required prerequisite did not become ready: $Description ($detail). No repair was attempted."
        }

        function Assert-ScopedSql {
            param($SiteVM, [string[]]$RequiredLogins = @(), [switch]$ConnectionOnly, [string]$InstanceNameOverride)
            $sqlName = if ($SiteVM.remoteSQLVM) { "$($SiteVM.remoteSQLVM)" } else { "$($SiteVM.vmName)" }
            $sqlVM = Get-ScopedConfigVM -Name $sqlName
            $sqlConfig = $deployConfig
            if ($InstanceNameOverride) {
                $sqlVM = $sqlVM.PSObject.Copy()
                $sqlVM | Add-Member -NotePropertyName sqlInstanceName -NotePropertyValue $InstanceNameOverride -Force
                $sqlVM | Add-Member -NotePropertyName sqlPort -NotePropertyValue 1433 -Force
                $sqlConfig = [pscustomobject]@{ virtualMachines = @($sqlVM) }
            }
            $dataSource = Get-VmSqlConnectionTarget -SiteVm $SiteVM -DeployConfig $sqlConfig -DomainFullName $DomainFullName
            $connection = $null
            try {
                $connectionString = "Data Source=$dataSource;Initial Catalog=master;Integrated Security=True;Connect Timeout=15;Encrypt=False;TrustServerCertificate=True"
                $connection = New-Object -TypeName System.Data.SqlClient.SqlConnection -ArgumentList $connectionString
                $connection.Open()
                if (-not $ConnectionOnly) {
                    $command = $connection.CreateCommand()
                    try {
                        $command.CommandText = 'SELECT state_desc FROM sys.databases WHERE name = @database'
                        $command.CommandTimeout = 30
                        [void]$command.Parameters.AddWithValue('@database', "CM_$($SiteVM.siteCode)")
                        $dbState = $command.ExecuteScalar()
                        if ("$dbState" -ne 'ONLINE') { throw "database CM_$($SiteVM.siteCode) is '$dbState', not ONLINE" }
                    }
                    finally { $command.Dispose() }
                }
                foreach ($login in $RequiredLogins) {
                    $command = $connection.CreateCommand()
                    try {
                        $command.CommandText = "SELECT IS_SRVROLEMEMBER('sysadmin', @login)"
                        $command.CommandTimeout = 30
                        [void]$command.Parameters.AddWithValue('@login', $login)
                        if ("$($command.ExecuteScalar())" -ne '1') {
                            throw "cannot prove existing sysadmin access for '$login'"
                        }
                    }
                    finally { $command.Dispose() }
                }
            }
            catch { throw "Required SQL prerequisite '$dataSource' for site '$($SiteVM.siteCode)' failed: $($_.Exception.Message). No SQL configuration was changed." }
            finally { if ($connection) { $connection.Dispose() } }
        }

        function Get-ScopedAdminState {
            param([string]$ComputerName, [string[]]$Accounts)
            return Invoke-CMRoleTargetCommand -ComputerName $ComputerName -ArgumentList @(,$Accounts) -ScriptBlock {
                param([string[]]$RequiredAccounts)
                $ErrorActionPreference = 'Stop'
                $members = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop)
                $missing = @($RequiredAccounts | Where-Object { $members.Name -inotcontains $_ })
                [pscustomobject]@{ Ready = $missing.Count -eq 0; Detail = "local Administrators missing [$($missing -join ', ')]" }
            }
        }

        function Get-ScopedComputerPrincipal {
            param([string]$Name)
            $computer = Get-ADComputer -Identity $Name -Server $DomainFullName -Properties Enabled -ErrorAction Stop
            if (-not $computer.Enabled -or $computer.SamAccountName -ine "$Name`$" -or -not $computer.SID) {
                throw "Required computer identity '$Name' is missing/disabled/inconsistent in '$DomainFullName'; no identity/trust repair was attempted."
            }
            $sid = [Security.Principal.SecurityIdentifier]::new("$($computer.SID)")
            if (-not $sid.IsAccountSid()) { throw "Required computer '$Name' did not resolve to an account SID." }
            $bytes = [byte[]]::new($sid.BinaryLength)
            $sid.GetBinaryForm($bytes, 0)
            [pscustomobject]@{
                AccountName = "$NetbiosDomainName\$Name`$"; Sid = $sid.Value; SidBytes = $bytes
                SidHex = '0x' + ([BitConverter]::ToString($bytes) -replace '-', '')
            }
        }

        function Assert-ScopedNewComputerProvisioning {
            param($Principal)
            $authorized = @($Payload.Targets | Where-Object {
                    $_.IsNewTarget -eq $true -and $_.role -eq 'PassiveSite' -and
                    $Principal.AccountName -ieq "$NetbiosDomainName\$($_.vmName)`$"
                })
            if ($authorized.Count -ne 1) { throw "No new-target computer binding is authorized for '$($Principal.AccountName)'." }
            $current = Get-ScopedComputerPrincipal -Name $authorized[0].vmName
            if ($current.Sid -ne $Principal.Sid) { throw "New computer identity changed before provisioning; no old binding was repaired." }
        }

        function Get-ScopedSqlComputerBindingTargets {
            $sqlName = if ($ThisVM.remoteSQLVM) { "$($ThisVM.remoteSQLVM)" } else { "$($ThisVM.vmName)" }
            $sqlVM = Get-ScopedConfigVM -Name $sqlName
            if (-not $sqlVM.AlwaysOnListenerName -and $sqlVM.role -ne 'SQLAO') {
                return Get-VmSqlConnectionTarget -SiteVm $ThisVM -DeployConfig $deployConfig -DomainFullName $DomainFullName
            }
            if (-not $sqlVM.OtherNode) { throw "Required existing SQLAO partner for '$sqlName' is unknown; no topology repair was attempted." }
            $partner = Get-ScopedConfigVM -Name $sqlVM.OtherNode
            if ($partner.OtherNode -ine $sqlName -or $partner.vmName -ieq $sqlName) {
                throw "Required existing SQLAO partner mapping for '$sqlName' is inconsistent; no topology repair was attempted."
            }
            foreach ($node in @($sqlVM, $partner)) {
                $copy = $node.PSObject.Copy()
                $copy | Add-Member -NotePropertyName AlwaysOnListenerName -NotePropertyValue '' -Force
                $site = [pscustomobject]@{ vmName = $ThisVM.vmName; remoteSQLVM = $node.vmName }
                $config = [pscustomobject]@{ virtualMachines = @($copy) }
                Get-VmSqlConnectionTarget -SiteVm $site -DeployConfig $config -DomainFullName $DomainFullName
            }
        }

        function Invoke-ScopedSqlComputerBinding {
            param($Principal, [switch]$Apply, [string]$DataSourceOverride)
            if ($Apply) { Assert-ScopedNewComputerProvisioning -Principal $Principal }
            if (-not $DataSourceOverride) {
                $needsGrant = $false
                foreach ($sqlTarget in @(Get-ScopedSqlComputerBindingTargets)) {
                    $binding = Invoke-ScopedSqlComputerBinding -Principal $Principal -Apply:$Apply -DataSourceOverride $sqlTarget
                    if ($binding.NeedsGrant) { $needsGrant = $true }
                }
                return [pscustomobject]@{ NeedsGrant = $needsGrant }
            }
            $dataSource = $DataSourceOverride
            $connection = $null
            try {
                $connection = New-Object -TypeName System.Data.SqlClient.SqlConnection -ArgumentList `
                    "Data Source=$dataSource;Initial Catalog=master;Integrated Security=True;Connect Timeout=15;Encrypt=False;TrustServerCertificate=True"
                $connection.Open()
                $command = $connection.CreateCommand()
                try {
                    $command.CommandTimeout = 30
                    $command.CommandText = 'SELECT name, type, is_disabled, CONVERT(varchar(172), sid, 1) AS SidHex FROM sys.server_principals WHERE name = @login FOR JSON PATH'
                    [void]$command.Parameters.AddWithValue('@login', $Principal.AccountName)
                    $json = "$($command.ExecuteScalar())"
                    $rows = @()
                    if ($json) {
                        $parsedRows = ConvertFrom-Json -InputObject $json -ErrorAction Stop
                        $rows = @($parsedRows | Where-Object { $null -ne $_ })
                    }
                    if ($rows.Count -gt 1 -or ($rows.Count -and ($rows[0].type -ne 'U' -or
                                $rows[0].is_disabled -ne 0 -or $rows[0].SidHex -ine $Principal.SidHex))) {
                        throw "Existing SQL principal '$($Principal.AccountName)' has conflicting identity/type/disabled state; it was not repaired."
                    }
                }
                finally { $command.Dispose() }
                $command = $connection.CreateCommand()
                try {
                    $command.CommandTimeout = 30
                    $command.CommandText = "SELECT IS_SRVROLEMEMBER('sysadmin', @login)"
                    [void]$command.Parameters.AddWithValue('@login', $Principal.AccountName)
                    $membership = "$($command.ExecuteScalar())"
                }
                finally { $command.Dispose() }
                if ($membership -eq '1') { return [pscustomobject]@{ NeedsGrant = $false } }
                if ($rows.Count -and $membership -ne '0') { throw "Cannot measure existing SQL membership for '$($Principal.AccountName)'." }
                if (-not $Apply) { return [pscustomobject]@{ NeedsGrant = $true } }
                Assert-ScopedBudget
                $command = $connection.CreateCommand()
                try {
                    $command.CommandTimeout = 30
                    $command.CommandText = @'
SET XACT_ABORT ON;
BEGIN TRY
    BEGIN TRANSACTION;
    IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @login AND (type <> 'U' OR is_disabled <> 0 OR sid <> @sid))
        THROW 51000, 'Existing computer login identity/state changed; no repair is permitted.', 1;
    DECLARE @statement nvarchar(max);
    IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @login)
    BEGIN
        SET @statement = N'CREATE LOGIN ' + QUOTENAME(@login) + N' FROM WINDOWS';
        EXEC sys.sp_executesql @statement;
    END;
    IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @login AND type = 'U' AND is_disabled = 0 AND sid = @sid)
        THROW 51000, 'Computer login identity changed during creation; no membership was granted.', 1;
    IF COALESCE(IS_SRVROLEMEMBER('sysadmin', @login), 0) <> 1
    BEGIN
        SET @statement = N'ALTER SERVER ROLE [sysadmin] ADD MEMBER ' + QUOTENAME(@login);
        EXEC sys.sp_executesql @statement;
    END;
    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
'@
                    [void]$command.Parameters.AddWithValue('@login', $Principal.AccountName)
                    [void]$command.Parameters.AddWithValue('@sid', $Principal.SidBytes)
                    $null = $command.ExecuteNonQuery()
                }
                finally { $command.Dispose() }
            }
            catch { throw "Required SQL computer binding on '$dataSource' failed for '$($Principal.AccountName)': $($_.Exception.Message)" }
            finally { if ($connection) { $connection.Dispose() } }
            $verified = Invoke-ScopedSqlComputerBinding -Principal $Principal -DataSourceOverride $dataSource
            if ($verified.NeedsGrant) { throw "New computer SQL binding for '$($Principal.AccountName)' did not verify; no existing principal was changed." }
            return $verified
        }

        function Invoke-ScopedPassiveAdminBinding {
            param([string]$ComputerName, $ActivePrincipal, $NewPrincipal, [switch]$Apply)
            if ($Apply) { Assert-ScopedNewComputerProvisioning -Principal $NewPrincipal }
            return Invoke-CMRoleTargetCommand -ComputerName $ComputerName `
                -ArgumentList @($ComputerName, $DomainFullName, $ActivePrincipal, $NewPrincipal, [bool]$Apply) -ScriptBlock {
                    param($ExpectedComputer, $ExpectedDomain, $Active, $NewComputer, [bool]$Provision)
                    $ErrorActionPreference = 'Stop'
                    $computer = Get-CimInstance -ClassName Win32_ComputerSystem -OperationTimeoutSec 30 -ErrorAction Stop
                    if ($computer.Name -ine ($ExpectedComputer -split '\.')[0] -or $computer.Domain -ine $ExpectedDomain -or
                        -not (Test-ComputerSecureChannel -ErrorAction Stop)) {
                        throw "Required existing '$ExpectedComputer' identity/trust is not healthy; no binding was changed."
                    }
                    foreach ($name in @('RpcSs', 'Winmgmt', 'LanmanServer', 'WinRM')) {
                        if ((Get-Service -Name $name -ErrorAction Stop).Status -ne 'Running') {
                            throw "Required existing '$ExpectedComputer' service '$name' is not Running; no service/binding repair was attempted."
                        }
                    }
                    $members = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop)
                    $activeIsSelf = $computer.Name -ieq ($Active.AccountName.Split('\')[-1].TrimEnd('$'))
                    if (-not $activeIsSelf -and @($members | Where-Object { "$($_.SID)" -eq $Active.Sid }).Count -ne 1) {
                        throw "Required existing active-site computer '$($Active.AccountName)' is not an administrator on '$ExpectedComputer'; no old relationship was repaired."
                    }
                    if (@($members | Where-Object { $_.Name -ieq $NewComputer.AccountName -and "$($_.SID)" -ne $NewComputer.Sid }).Count) {
                        throw "Existing '$($NewComputer.AccountName)' membership on '$ExpectedComputer' has a conflicting SID; no repair was attempted."
                    }
                    $needsGrant = @($members | Where-Object { "$($_.SID)" -eq $NewComputer.Sid }).Count -eq 0
                    if ($needsGrant -and $Provision) {
                        Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $NewComputer.Sid -ErrorAction Stop
                        $members = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop)
                        if (@($members | Where-Object { "$($_.SID)" -eq $NewComputer.Sid }).Count -ne 1) {
                            throw "New computer membership on '$ExpectedComputer' did not verify."
                        }
                        $needsGrant = $false
                    }
                    [pscustomobject]@{ NeedsGrant = $needsGrant }
                }
        }

        function Invoke-ScopedPassiveLibraryBinding {
            param([string]$ComputerName, $ActivePrincipal, $NewPrincipal, [switch]$Apply)
            if ($Apply) { Assert-ScopedNewComputerProvisioning -Principal $NewPrincipal }
            return Invoke-CMRoleTargetCommand -ComputerName $ComputerName `
                -ArgumentList @("$($Payload.SiteCode)", $ActivePrincipal, $NewPrincipal, [bool]$Apply) -ScriptBlock {
                    param($ShareName, $Active, $NewComputer, [bool]$Provision)
                    $ErrorActionPreference = 'Stop'
                    $share = Get-SmbShare -Name $ShareName -ErrorAction Stop
                    $folder = Join-Path $share.Path 'ContentLib'
                    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { throw "Required existing library '$folder' is missing; no share/directory was created." }
                    $shareAccess = @(Get-SmbShareAccess -Name $ShareName -ErrorAction Stop)
                    $acl = Get-Acl -LiteralPath $folder -ErrorAction Stop
                    $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
                    if (@($shareAccess | Where-Object AccessControlType -eq 'Deny').Count -or
                        @($rules | Where-Object AccessControlType -eq 'Deny').Count) {
                        throw 'Required existing library contains deny entries; effective access cannot be proved without changing old ACL policy. No ACL was changed.'
                    }
                    $commonSids = @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-544')
                    $commonNames = @($commonSids | ForEach-Object {
                            ([Security.Principal.SecurityIdentifier]$_).Translate([Security.Principal.NTAccount]).Value
                        })
                    $needs = @{}
                    foreach ($principal in @($Active, $NewComputer)) {
                        $names = @($principal.AccountName, $principal.Sid) + $commonNames
                        $sids = @($principal.Sid) + $commonSids
                        if (@($shareAccess | Where-Object { $_.AccountName -in $names -and $_.AccessControlType -eq 'Deny' }).Count -or
                            @($rules | Where-Object { "$($_.IdentityReference)" -in $sids -and $_.AccessControlType -eq 'Deny' }).Count) {
                            throw "Required library access for '$($principal.AccountName)' has an existing deny; no deny/ACL repair was attempted."
                        }
                        $hasShare = @($shareAccess | Where-Object {
                                $_.AccountName -in $names -and $_.AccessControlType -eq 'Allow' -and $_.AccessRight -eq 'Full'
                            }).Count -gt 0
                        $hasNtfs = @($rules | Where-Object {
                                "$($_.IdentityReference)" -in $sids -and $_.AccessControlType -eq 'Allow' -and
                                ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl
                            }).Count -gt 0
                        if ($principal.AccountName -ieq $Active.AccountName -and (-not $hasShare -or -not $hasNtfs)) {
                            throw "Required existing library grants for '$($Active.AccountName)' are broken; no old principal/ACL was repaired."
                        }
                        $needs[$principal.AccountName] = @{ Share = -not $hasShare; Ntfs = -not $hasNtfs }
                    }
                    $missing = $needs[$NewComputer.AccountName]
                    if ($Provision) {
                        if ($missing.Share) {
                            Grant-SmbShareAccess -Name $ShareName -AccountName $NewComputer.AccountName -AccessRight Full -Force -ErrorAction Stop | Out-Null
                        }
                        if ($missing.Ntfs) {
                            $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
                            $rule = [Security.AccessControl.FileSystemAccessRule]::new(
                                [Security.Principal.SecurityIdentifier]::new($NewComputer.Sid),
                                [Security.AccessControl.FileSystemRights]::FullControl, $inheritance,
                                [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
                            $acl.AddAccessRule($rule)
                            Set-Acl -LiteralPath $folder -AclObject $acl -ErrorAction Stop
                        }
                    }
                    [pscustomobject]@{ NeedsGrant = $missing.Share -or $missing.Ntfs }
                }
        }

        function Get-ScopedRoleConfiguration {
            param([string]$Role, [string]$Fqdn, [string]$Code)
            $rows = @()
            switch ($Role) {
                'DP' { $rows = @(Get-CMDistributionPoint -SiteSystemServerName $Fqdn -SiteCode $Code -ErrorAction Stop) }
                'MP' { $rows = @(Get-CMManagementPoint -SiteSystemServerName $Fqdn -SiteCode $Code -ErrorAction Stop) }
                'SUP' { $rows = @(Get-CMSoftwareUpdatePoint -SiteSystemServerName $Fqdn -SiteCode $Code -ErrorAction Stop) }
                'RP' {
                    $rows = @(Get-CMReportingServicePoint -SiteSystemServerName $Fqdn -ErrorAction Stop | Where-Object { $null -ne $_ })
                    if (@($rows | Where-Object { $_.SiteCode -ine $Code }).Count) {
                        throw "Reporting point '$Fqdn' belongs to a different site, not '$Code'."
                    }
                }
            }
            $rows = @($rows | Where-Object { $null -ne $_ })
            if ($rows.Count -gt 1) { throw "Ambiguous $Role configuration for '$Fqdn' in site '$Code'." }
            return $rows
        }

        function Get-ScopedRoleReadiness {
            param([string]$Role, [string]$Fqdn, [string]$Code)
            $state = $null
            switch ($Role) {
                'DP' { $state = Get-CMDistributionPointReadiness -ServerFQDN $Fqdn -SiteCode $Code }
                'MP' { $state = Get-CMManagementPointReadiness -ServerFQDN $Fqdn -SiteCode $Code }
                'SUP' { $state = Get-CMSoftwareUpdatePointReadiness -ServerFQDN $Fqdn -SiteCode $Code }
                'RP' { $state = Get-CMReportingPointReadiness -ServerFQDN $Fqdn -SiteCode $Code }
            }
            if ($Role -eq 'MP' -and $usePKI -and $state.Ready -and -not (Test-MPHttpsBinding -MPFQDN $Fqdn)) {
                return [pscustomobject]@{ Ready = $false; Detail = "$($state.Detail); HTTPS binding/certificate is not ready" }
            }
            return $state
        }

        function Get-ScopedRetainedSourceDpReadiness {
            param([string]$Fqdn, [string]$Code)
            $job = $null
            try {
                $configuration = @(Get-CMDistributionPoint -SiteSystemServerName $Fqdn -SiteCode $Code -ErrorAction Stop |
                        Where-Object { $null -ne $_ })
                if ($configuration.Count -ne 1) {
                    return [pscustomobject]@{ Ready = $false; Detail = "source DP configuration rows=$($configuration.Count)" }
                }
                $shortName = ($Fqdn -split '\.')[0]
                $provider = @(Get-WmiObject -Namespace "root\SMS\site_$Code" -Class SMS_DistributionPointInfo -ErrorAction Stop |
                        Where-Object {
                            "$($_.ServerName)".TrimStart('\') -ieq $Fqdn -or "$($_.ServerName)".TrimStart('\') -ieq $shortName -or
                            "$($_.NetworkOSPath)".TrimStart('\') -ieq $Fqdn -or "$($_.NetworkOSPath)".TrimStart('\') -ieq $shortName
                        })
                if ($provider.Count -ne 1) {
                    return [pscustomobject]@{ Ready = $false; Detail = "source DP provider rows=$($provider.Count)" }
                }
                # The shared DP producer-readiness helper writes an access probe.
                # A retained pull-DP source must only be read, never probed by writing.
                $job = Start-Job -ArgumentList $Fqdn -ScriptBlock {
                    param([string]$Server)
                    $ErrorActionPreference = 'Stop'
                    $path = "FileSystem::\\$Server\SMS_DP`$"
                    $null = Get-Item -LiteralPath $path -Force -ErrorAction Stop
                    $null = Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop | Select-Object -First 1
                    [pscustomobject]@{ Ready = $true; Detail = 'source DP configuration/provider present and SMS_DP$ readable (read-only)' }
                }
                if (-not (Wait-Job -Job $job -Timeout 20)) {
                    return [pscustomobject]@{ Ready = $false; Detail = 'source DP read-only access probe timed out after 20 seconds' }
                }
                $result = @(Receive-Job -Job $job -ErrorAction Stop | Where-Object { $null -ne $_ })
                if ($result.Count -ne 1 -or $result[0].Ready -isnot [bool]) {
                    throw 'Source DP read-only probe returned no unique structured result.'
                }
                return $result[0]
            }
            catch { return [pscustomobject]@{ Ready = $false; Detail = "source DP read-only readiness failed: $($_.Exception.Message)" } }
            finally {
                if ($job) {
                    if ($job.State -eq 'Running') { Stop-Job -Job $job -ErrorAction Stop }
                    Remove-Job -Job $job -ErrorAction Stop
                }
            }
        }

        function Assert-ScopedTargetPrerequisites {
            param($Target, [string]$Role)
            $fqdn = Get-ScopedFqdn $Target.vmName
            $null = Wait-ScopedObservation -Description "$Role producer prerequisites on '$fqdn'" -Probe {
                $state = Get-CMRoleTargetPrerequisiteState -ServerFQDN $fqdn -RoleName $Role
                $missing = @($state.MissingFeatures | Where-Object { $_ })
                if ($missing.Count -or ($state.GuestProbeReady -eq $true -and
                        ($state.IdentityReady -ne $true -or $state.SiteServerAdmin -ne $true))) {
                    throw "Required Phase 3 prerequisite on requested '$fqdn' cannot be supplied by Phase 8 ($($state.Detail)). No feature/account repair was attempted."
                }
                return $state
            }
            if ($usePKI -and $Role -eq 'MP') {
                $null = Wait-ScopedObservation -Description "Phase 8 IIS HTTPS binding on '$fqdn'" -Probe {
                    [pscustomobject]@{ Ready = (Test-MPHttpsBinding -MPFQDN $fqdn); Detail = 'a valid IIS HTTPS certificate/binding is required' }
                }
            }
            $siteVMs = @($deployConfig.virtualMachines | Where-Object {
                    $_ -and $_.siteCode -ieq $Target.siteCode -and $_.role -in @('Primary', 'Secondary')
                })
            if ($siteVMs.Count -ne 1) { throw "Cannot uniquely identify the site server for '$fqdn' (site $($Target.siteCode))." }
            $accounts = @(@($ThisVM.vmName, $siteVMs[0].vmName) |
                Where-Object { $_ -ine $Target.vmName } |
                Select-Object -Unique | ForEach-Object { "$NetbiosDomainName\$_`$" })
            $state = Get-ScopedAdminState -ComputerName $fqdn -Accounts $accounts
            if (-not $state.Ready) { throw "Required site-server account access on requested '$fqdn' failed ($($state.Detail)). No account grants were changed." }
        }

        function Initialize-ScopedSiteSystem {
            param([string]$Fqdn, [string]$Code)
            $systems = @(Get-CMSiteSystemServer -SiteSystemServerName $Fqdn -SiteCode $Code -ErrorAction Stop | Where-Object { $null -ne $_ })
            if ($systems.Count -gt 1) { throw "Ambiguous site system '$Fqdn' in site '$Code'." }
            if ($systems.Count -eq 1) { return $systems[0] }
            Assert-ScopedBudget
            $null = New-CMSiteSystemServer -SiteSystemServerName $Fqdn -SiteCode $Code -ErrorAction Stop
            $observation = Wait-ScopedObservation -Seconds 180 -Description "native site-system registration '$Fqdn' ($Code)" -Probe {
                $rows = @(Get-CMSiteSystemServer -SiteSystemServerName $Fqdn -SiteCode $Code -ErrorAction Stop | Where-Object { $null -ne $_ })
                if ($rows.Count -gt 1) { throw "Ambiguous site system '$Fqdn' in site '$Code' after submission." }
                [pscustomobject]@{ Ready = $rows.Count -eq 1; Value = $rows; Detail = 'site-system provider row not visible' }
            }
            return $observation.Value[0]
        }

        function Get-ScopedDpCertificate {
            $certPath = 'C:\temp\ConfigMgrClientDistributionPointCertificate.pfx'
            if (-not (Test-Path -LiteralPath $certPath -PathType Leaf)) {
                throw "Required existing PKI input is missing: '$certPath'. No certificate repair/export was attempted."
            }
            if ($Admincreds -isnot [Management.Automation.PSCredential]) {
                throw 'Required in-memory Admincreds credential for the existing DP certificate was not supplied.'
            }
            return @{ CertificatePath = $certPath; CertificatePassword = $Admincreds.Password }
        }

        function Assert-ScopedUpstreamSup {
            param([string]$Code)
            $site = Get-ScopedSite -Code $Code
            $upstreamCode = "$($site.ReportingSiteCode)"
            if (-not $upstreamCode) { return }
            $upstream = Get-ScopedSite -Code $upstreamCode
            if ($upstream.Status -ne 1) { throw "Required upstream site '$upstreamCode' is not Active; no parent-site repair was attempted." }
            Assert-MemLabsSelectedSupPrerequisite -SiteContext ([pscustomobject]@{
                    SiteCode = $upstreamCode; Fqdn = Get-ScopedFqdn ("$($upstream.ServerName)".TrimStart('\'))
                })
        }

        function Invoke-ScopedRoleAddition {
            param($Target, [string]$Role)
            $fqdn = Get-ScopedFqdn $Target.vmName
            $code = "$($Target.siteCode)"
            $existing = @(Get-ScopedRoleConfiguration -Role $Role -Fqdn $fqdn -Code $code)
            if ($existing.Count) {
                $readiness = Get-ScopedRoleReadiness -Role $Role -Fqdn $fqdn -Code $code
                if (-not $readiness.Ready) {
                    throw "Requested existing $Role '$fqdn' in '$code' is not healthy ($($readiness.Detail)). No role recovery was attempted."
                }
                return $false
            }
            Assert-ScopedTargetPrerequisites -Target $Target -Role $Role
            $arguments = @{ SiteSystemServerName = $fqdn; SiteCode = $code; ErrorAction = 'Stop' }
            if ($Role -eq 'DP') {
                if ($Target.enablePullDP) {
                    $sourceName = "$($Target.pullDPSourceDP)".Trim()
                    if (-not $sourceName -or $sourceName.TrimEnd('.') -ieq $fqdn -or $sourceName -ieq $Target.vmName) {
                        throw "Pull DP '$fqdn' needs a different, explicit source DP."
                    }
                    $sourceFqdn = Get-ScopedFqdn $sourceName
                    $sourceIsRequested = @($Payload.Targets | Where-Object {
                            (Get-ScopedFqdn $_.vmName) -ieq $sourceFqdn -and $_.installDP -and -not $_.enablePullDP -and $_.siteCode -ieq $code
                        }).Count -eq 1
                    if (-not $sourceIsRequested) {
                        $source = Get-ScopedRetainedSourceDpReadiness -Fqdn $sourceFqdn -Code $code
                        if (-not $source.Ready) {
                            throw "Required retained source DP '$sourceFqdn' for pull DP '$fqdn' is not ready ($($source.Detail)). No source-DP repair was attempted."
                        }
                    }
                    else {
                        $null = Wait-ScopedObservation -Description "new source DP '$sourceFqdn' for '$fqdn'" -Probe {
                            Get-CMDistributionPointReadiness -ServerFQDN $sourceFqdn -SiteCode $code
                        }
                    }
                    $arguments.EnablePullDP = $true
                    $arguments.SourceDistributionPoint = $sourceFqdn
                }
                else {
                    $arguments.EnablePxe = $true
                    $arguments.EnableNonWdsPxe = $true
                    $arguments.AllowPxeResponse = $true
                    $arguments.EnableUnknownComputerSupport = $true
                }
                $arguments.Force = $true
                if ($usePKI) {
                    $certificate = Get-ScopedDpCertificate
                    $arguments.CertificatePath = $certificate.CertificatePath
                    $arguments.CertificatePassword = $certificate.CertificatePassword
                    if (-not $Target.enablePullDP) { $arguments.EnableSSL = $true }
                }
                else { $arguments.CertificateExpirationTimeUtc = [DateTime]::UtcNow.AddYears(30) }
            }
            elseif ($Role -eq 'SUP') {
                Assert-ScopedUpstreamSup -Code $code
                $arguments.WsusIisPort = 8530
                $arguments.WsusIisSslPort = 8531
                $arguments.WsusSSL = $usePKI
            }
            elseif ($Role -eq 'RP') {
                $reportUser = "$NetbiosDomainName\cm_svc"
                $accounts = @(Get-CMAccount -SiteCode $code -UserName $reportUser -ErrorAction Stop |
                        Where-Object { $_.UserName -ieq $reportUser })
                if ($accounts.Count -ne 1) {
                    throw "Required existing reporting account '$reportUser' is not present uniquely in site '$code'. No account was created or reset."
                }
                $arguments.UserName = $reportUser
                $arguments.DatabaseServerName = Get-VmSqlConnectionTarget -SiteVm $ThisVM -DeployConfig $deployConfig -DomainFullName $DomainFullName
                $arguments.DatabaseName = "CM_$code"
                $arguments.ReportServerInstance = 'PBIRS'
            }
            $system = Initialize-ScopedSiteSystem -Fqdn $fqdn -Code $code
            Assert-ScopedBudget
            Write-DscStatus "Submitting requested $Role on '$fqdn' in site '$code'."
            switch ($Role) {
                'DP' { $null = Add-CMDistributionPoint @arguments }
                'MP' {
                    $mpArguments = @{ InputObject = $system; CommunicationType = 'Http'; ErrorAction = 'Stop' }
                    if ($usePKI) { $mpArguments.CommunicationType = 'Https'; $mpArguments.EnableSSL = $true }
                    $null = Add-CMManagementPoint @mpArguments
                }
                'SUP' { $null = Add-CMSoftwareUpdatePoint @arguments }
                'RP' { $null = Add-CMReportingServicePoint @arguments }
            }
            $null = Wait-ScopedObservation -Seconds 180 -Description "$Role native configuration on '$fqdn' ($code)" -Probe {
                [pscustomobject]@{
                    Ready = @(Get-ScopedRoleConfiguration -Role $Role -Fqdn $fqdn -Code $code).Count -eq 1
                    Detail = 'native role registration not visible'
                }
            }
            $null = Wait-ScopedObservation -Description "$Role physical readiness on requested '$fqdn' ($code)" `
                -ConsecutiveSuccesses 2 -Probe {
                    Get-ScopedRoleReadiness -Role $Role -Fqdn $fqdn -Code $code
                }
        }

        function Invoke-ScopedSecondary {
            param($Target)
            $fqdn = Get-ScopedFqdn $Target.vmName
            $code = "$($Target.siteCode)"
            if ($Target.parentSiteCode -ine $Payload.SiteCode) {
                throw "Secondary '$fqdn' is not a child of owning Primary '$($Payload.SiteCode)'."
            }
            $site = Get-ScopedSite -Code $code -AllowMissing
            if ($site) {
                if ($site.Type -ne 1 -or $site.ReportingSiteCode -ine $Payload.SiteCode -or
                    "$($site.ServerName)".TrimStart('\') -ine $fqdn) {
                    throw "Site '$code' already belongs to a different server/parent/type; no site object was changed."
                }
                if ($site.Status -notin @(1, 2)) { throw "Required requested secondary '$code' is in failed/unknown Status=$($site.Status). No recovery was requested." }
                if ($site.Status -eq 1) {
                    foreach ($role in @('DP', 'MP')) {
                        $state = Get-ScopedRoleReadiness -Role $role -Fqdn $fqdn -Code $code
                        if (-not $state.Ready) { throw "Required existing secondary '$code' $role is not ready ($($state.Detail)). No recovery was requested." }
                    }
                    if ($usePKI -and -not (Test-MPHttpsBinding -MPFQDN $fqdn)) {
                        throw "Required existing secondary '$code' HTTPS MP binding is not ready. No IIS/certificate repair was attempted."
                    }
                }
            }
            else {
                $parentMps = @(Get-CMManagementPoint -SiteCode $Payload.SiteCode -ErrorAction Stop | Where-Object { $null -ne $_ })
                $parentReady = $false
                foreach ($mp in $parentMps) {
                    $mpName = "$($mp.NetworkOSPath)".TrimStart('\')
                    if (-not $mpName) { throw "Required parent MP in '$($Payload.SiteCode)' has no NetworkOSPath." }
                    if ((Get-CMManagementPointReadiness -ServerFQDN $mpName -SiteCode $Payload.SiteCode).Ready) { $parentReady = $true; break }
                }
                if (-not $parentReady) {
                    throw "Required parent Primary '$($Payload.SiteCode)' has no healthy MP for secondary '$code'. No parent MP was installed/repaired."
                }
                foreach ($role in @('DP', 'MP')) { Assert-ScopedTargetPrerequisites -Target $Target -Role $role }
                if ($Target.sqlVersion) {
                    $targetVM = Get-ScopedConfigVM -Name $Target.vmName
                    Assert-ScopedSql -SiteVM $targetVM -ConnectionOnly
                }
                $arguments = @{
                    PrimarySiteCode = "$($Payload.SiteCode)"; SecondarySiteCode = $code; ServerName = $fqdn
                    InstallationFolder = 'C:\Program Files\Microsoft Configuration Manager'
                    InstallationSourceFile = (New-CMInstallationSourceFile -CopyFromParentSiteServer -ErrorAction Stop)
                    InstallInternetServer = $true; SiteName = 'Secondary Site'; ErrorAction = 'Stop'
                }
                if ($Target.cmInstallDir) { $arguments.InstallationFolder = "$($Target.cmInstallDir)" }
                if ($Target.siteName) { $arguments.SiteName = "$($Target.siteName)" }
                $sqlArguments = @{ SqlServerServiceBrokerPort = 4022; ErrorAction = 'Stop' }
                if ($Target.sqlVersion) {
                    $sqlArguments.UseExistingSqlServerInstance = $true
                    $sqlArguments.SiteDatabaseName = "CM_$code"
                    if ($Target.sqlInstanceName -and $Target.sqlInstanceName -ine 'MSSQLSERVER') {
                        $sqlArguments.InstanceName = "$($Target.sqlInstanceName)"
                    }
                }
                else { $sqlArguments.CopySqlServerExpressOnSecondarySite = $true; $sqlArguments.SqlServerServicePort = 1433 }
                $arguments.SqlServerSetting = New-CMSqlServerSetting @sqlArguments
                if ($usePKI) {
                    $certificate = Get-ScopedDpCertificate
                    $arguments.Https = $true
                    $arguments.ImportCertificate = $true
                    $arguments.CertificatePath = $certificate.CertificatePath
                    $arguments.CertificatePassword = $certificate.CertificatePassword
                    $arguments.ForceWhenDuplicateCertificate = $true
                }
                else {
                    $arguments.Http = $true
                    $arguments.CreateSelfSignedCertificate = $true
                    $arguments.CertificateExpirationTimeUtc = [DateTime]::UtcNow.AddYears(30)
                }
                Write-DscStatus "Submitting requested secondary '$fqdn' ($code) under '$($Payload.SiteCode)'."
                Assert-ScopedBudget
                $null = New-CMSecondarySite @arguments
                $null = Wait-ScopedObservation -Seconds 180 -Description "secondary '$code' native acceptance" -Probe {
                    $nativeSite = Get-ScopedSite -Code $code -AllowMissing
                    if ($nativeSite -and ($nativeSite.Status -notin @(1, 2) -or $nativeSite.Type -ne 1 -or
                            $nativeSite.ReportingSiteCode -ine $Payload.SiteCode -or
                            "$($nativeSite.ServerName)".TrimStart('\') -ine $fqdn)) {
                        throw "Secondary '$code' returned failed/conflicting native state after submission."
                    }
                    [pscustomobject]@{ Ready = [bool]$nativeSite; Detail = 'secondary provider row not visible' }
                }
            }
            $null = Wait-ScopedObservation -Seconds 5400 -Description "native secondary '$code' activation" -Probe {
                $nativeSite = Get-ScopedSite -Code $code
                if ($nativeSite.Status -notin @(1, 2)) { throw "Secondary '$code' failed with Status=$($nativeSite.Status); no recovery was requested." }
                [pscustomobject]@{ Ready = $nativeSite.Status -eq 1; Detail = "native secondary Status=$($nativeSite.Status)" }
            }
            $targetVM = Get-ScopedConfigVM -Name $Target.vmName
            if ($Target.sqlVersion) { Assert-ScopedSql -SiteVM $targetVM }
            else { Assert-ScopedSql -SiteVM $targetVM -InstanceNameOverride CONFIGMGRSEC }
            foreach ($role in @('DP', 'MP')) {
                $null = Wait-ScopedObservation -Description "secondary '$code' implicit $role physical readiness" `
                    -ConsecutiveSuccesses 2 -Probe {
                        Get-ScopedRoleReadiness -Role $role -Fqdn $fqdn -Code $code
                    }
            }
            $null = Wait-ScopedObservation -Description "secondary '$code' native DRS readiness" -Probe {
                $rows = @(Get-CMDatabaseReplicationStatus -Site1 $Payload.SiteCode -Site2 $code -ErrorAction Stop |
                        Where-Object { $null -ne $_ })
                if ($rows.Count -gt 1) { throw "Ambiguous DRS link for secondary '$code' under '$($Payload.SiteCode)'." }
                $replication = $null
                if ($rows.Count) { $replication = $rows[0] }
                if (Test-SecondarySiteReplicationActive -ReplicationStatus $replication) {
                    return [pscustomobject]@{ Ready = $true; Detail = 'secondary DRS link and both global directions are Active' }
                }
                if ($replication -and ($replication.LinkStatus -in @(6, 8, 9) -or
                        $replication.Site1ToSite2GlobalState -in @(6, 8, 9) -or
                        $replication.Site2ToSite1GlobalState -in @(6, 8, 9))) {
                    throw "Required secondary '$code' DRS link is failed/degraded (Link=$($replication.LinkStatus)). Aggregate SQL state cannot prove requested-link readiness. No DRS reinitialization was attempted."
                }
                [pscustomobject]@{
                    Ready = $false
                    Detail = "DRS Link=$($replication.LinkStatus), parent-to-child=$($replication.Site1ToSite2GlobalState), child-to-parent=$($replication.Site2ToSite1GlobalState)"
                }
            }
        }

        function Wait-ScopedPassiveReady {
            param([string]$Fqdn)
            $stability = @{ ReadySince = $null }
            $null = Wait-ScopedObservation -Description "passive '$Fqdn' stably Ready for 300 seconds with SMS_EXECUTIVE Running" -Probe {
                $rows = @(Get-WmiObject -Namespace "root\SMS\site_$($Payload.SiteCode)" -Class SMS_SCI_SysResUse `
                        -Filter "RoleName = 'SMS Site Server' AND SiteCode = '$($Payload.SiteCode)' AND SiteSystemStatus = 0" -ErrorAction Stop |
                        Where-Object { $null -ne $_ })
                if ($rows.Count -gt 1 -or @($rows | Where-Object { "$($_.NetworkOSPath)".TrimStart('\') -ine $Fqdn }).Count) {
                    throw "Conflicting passive site-server rows in site '$($Payload.SiteCode)'; no object was changed."
                }
                $state = 0
                if ($rows.Count -and $null -ne $rows[0].ServerState) { $state = [int]$rows[0].ServerState }
                if ($state -gt 0 -and ('{0:X4}' -f ($state % 65536)).StartsWith('F')) {
                    throw "Requested passive '$Fqdn' is not stably Ready (ServerState=$state). No RetryInstallation or service recovery was requested."
                }
                $serviceReady = $false
                if (($state -band 0xFFFF0000) -eq 0x00030000) {
                    $serviceReady = Invoke-CMRoleTargetCommand -ComputerName $Fqdn -ScriptBlock {
                        try { return (Get-Service -Name SMS_EXECUTIVE -ErrorAction Stop).Status -eq 'Running' }
                        catch {
                            if ($_.CategoryInfo.Category -ne 'ObjectNotFound') { throw }
                            return $false
                        }
                    }
                }
                if (($state -band 0xFFFF0000) -eq 0x00030000 -and $serviceReady -eq $true) {
                    if (-not $stability.ReadySince) { $stability.ReadySince = Get-Date }
                    $stableSeconds = ((Get-Date) - $stability.ReadySince).TotalSeconds
                    return [pscustomobject]@{ Ready = $stableSeconds -ge 300; Detail = "ServerState=$state, stable ready seconds=$stableSeconds, SMS_EXECUTIVE=Running" }
                }
                $stability.ReadySince = $null
                [pscustomobject]@{ Ready = $false; Detail = "ServerState=$state, SMS_EXECUTIVE Running=$serviceReady" }
            }
        }

        function Get-ScopedLibraryPathKey {
            param([string]$Path)
            $value = "$Path".Trim().TrimEnd('\')
            if ($value -match '^\\\\([^\\]+)\\(.+)$') {
                $server = $Matches[1].TrimEnd('.')
                $relative = $Matches[2]
                if ($server.EndsWith(".$DomainFullName", [StringComparison]::OrdinalIgnoreCase)) {
                    $server = $server.Substring(0, $server.Length - $DomainFullName.Length - 1)
                }
                $value = "\\$server\$relative"
            }
            return $value.ToLowerInvariant()
        }

        function Get-ScopedLibraryNativeState {
            $sites = @(Get-CimInstance -Namespace "root\SMS\site_$($Payload.SiteCode)" -ClassName SMS_Site `
                    -OperationTimeoutSec 30 -ErrorAction Stop | Where-Object { $null -ne $_ })
            $owner = @($sites | Where-Object { $_.SiteCode -ieq $Payload.SiteCode })
            if ($owner.Count -ne 1 -or "$($owner[0].ServerName)".TrimStart('\') -ine (Get-ScopedFqdn $ThisVM.vmName)) {
                throw "Native content-library site identity is not unique on '$($ThisVM.vmName)' for '$($Payload.SiteCode)'."
            }
            $pointers = Invoke-CMRoleTargetCommand -ComputerName (Get-ScopedFqdn $ThisVM.vmName) -ScriptBlock {
                $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
                    [Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
                $key = $null
                try {
                    $key = $base.OpenSubKey('Software\Microsoft\SMS\DP', $false)
                    if (-not $key) { throw 'Required native 64-bit SMS\DP registry key is absent.' }
                    foreach ($name in @('ContentLibraryPath', 'ContentLibUsableDrives')) {
                        if ($key.GetValueKind($name) -ne [Microsoft.Win32.RegistryValueKind]::String) {
                            throw "Required native '$name' is not REG_SZ; no registry repair was attempted."
                        }
                    }
                    [pscustomobject]@{
                        Path = [string]$key.GetValue('ContentLibraryPath')
                        Drives = [string]$key.GetValue('ContentLibUsableDrives')
                    }
                }
                finally { if ($key) { $key.Dispose() }; $base.Dispose() }
            }
            if ([string]::IsNullOrWhiteSpace($pointers.Path)) { throw 'Required native current content-library pointer is empty; no repair was attempted.' }
            $check = Invoke-CimMethod -Namespace "root\SMS\site_$($Payload.SiteCode)" -ClassName SMS_Site `
                -MethodName RunPrereqCheck -Arguments @{ SiteCode = "$($Payload.SiteCode)" } `
                -OperationTimeoutSec 30 -ErrorAction Stop
            if ($null -eq $check.ReturnValue -or [int]$check.ReturnValue -ne 0 -or
                -not $check.PSObject.Properties['Result'] -or $null -eq $check.Result) {
                throw "Site-specific RunPrereqCheck did not return ReturnValue=0 and a PRESENT Result for '$($Payload.SiteCode)'."
            }
            [pscustomobject]@{
                Sites = $sites; Location = "$($owner[0].ContentLibraryLocation)"
                Path = "$($pointers.Path)"; Drives = "$($pointers.Drives)"; Result = [int]$check.Result
            }
        }

        function Assert-ScopedLibraryCollisionFree {
            param($State, [string]$Destination)
            $dest = Get-ScopedLibraryPathKey $Destination
            $destServer = ($Destination.TrimStart('\') -split '\\')[0].Split('.')[0]
            foreach ($site in @($State.Sites | Where-Object { $_.SiteCode -ine $Payload.SiteCode })) {
                if (-not $site.ContentLibraryLocation) {
                    if (("$($site.ServerName)".TrimStart('\') -split '\.')[0] -ieq $destServer) {
                        throw "Cannot prove no library collision with site '$($site.SiteCode)' on the selected destination host: its native location is absent."
                    }
                    continue
                }
                $other = Get-ScopedLibraryPathKey "$($site.ContentLibraryLocation)"
                if ($other -eq $dest -or $other.StartsWith("$dest\", [StringComparison]::OrdinalIgnoreCase) -or
                    $dest.StartsWith("$other\", [StringComparison]::OrdinalIgnoreCase)) {
                    throw "Selected content-library destination collides with site '$($site.SiteCode)'; no library mutation was requested."
                }
            }
        }

        function Invoke-ScopedLibraryDestination {
            param($Target, [string]$Destination, $ActivePrincipal, $PassivePrincipal, [switch]$Reserve, $State)
            Assert-ScopedBudget
            $configured = Get-ScopedConfigVM -Name $Target.vmName
            $run = $configured.phase8ScopedHierarchyAction
            if ($Reserve -and (-not $run.RunId -or $run.OwnerVMName -ine $ThisVM.vmName -or $run.Kind -ne 'SiteRoles')) {
                throw 'Content-library reservation requires the parent-supplied owner action RunId identity.'
            }
            $identity = [pscustomobject]@{
                SchemaVersion = 1; OwnerVMName = "$($ThisVM.vmName)"; SiteCode = "$($Payload.SiteCode)"
                Destination = $Destination; DestinationVMName = "$($Target.remoteContentLibVM)"
                DestinationDomainName = "$DomainFullName"; RunId = "$($run.RunId)"
            }
            $references = [Collections.Generic.List[object]]::new()
            if ($State) {
                $inputs = @([pscustomobject]@{ SiteCode = "$($Payload.SiteCode)"; ServerName = $ThisVM.vmName; Location = $State.Path; IsSource = $true })
                $inputs += @($State.Sites | Where-Object { $_.SiteCode -ine $Payload.SiteCode -and $_.ContentLibraryLocation } |
                        ForEach-Object { [pscustomobject]@{ SiteCode = $_.SiteCode; ServerName = $_.ServerName; Location = $_.ContentLibraryLocation; IsSource = $false } })
                foreach ($reference in $inputs) {
                    Assert-ScopedBudget
                    if ($reference.IsSource -and -not $Reserve) { continue }
                    $hostName = "$($reference.ServerName)".TrimStart('\')
                    if ("$($reference.Location)" -match '^\\\\([^\\]+)\\') { $hostName = $Matches[1] }
                    $computer = Get-CimInstance -ComputerName $hostName -ClassName Win32_ComputerSystem -OperationTimeoutSec 30 -ErrorAction Stop
                    if (-not $computer.Name) { throw "Cannot resolve content-library filesystem identity for '$hostName'." }
                    $references.Add([pscustomobject]@{
                            SiteCode = $reference.SiteCode; ComputerName = "$($computer.Name)"
                            Location = "$($reference.Location)"; IsSource = $reference.IsSource
                        })
                }
            }
            return Invoke-CMRoleTargetCommand -ComputerName (Get-ScopedFqdn $Target.remoteContentLibVM) `
                -ArgumentList @($identity, $ActivePrincipal, $PassivePrincipal, [bool]$Reserve, $references.ToArray()) -ScriptBlock {
                    param($Identity, $Active, $Passive, [bool]$CreateReservation, $References)
                    $ErrorActionPreference = 'Stop'
                    $computer = Get-CimInstance -ClassName Win32_ComputerSystem -OperationTimeoutSec 30 -ErrorAction Stop
                    if ($computer.Name -ine $Identity.DestinationVMName -or $computer.Domain -ine $Identity.DestinationDomainName -or
                        $computer.Name -ieq $Identity.OwnerVMName -or
                        -not (Test-ComputerSecureChannel -ErrorAction Stop)) {
                        throw 'Selected remote library host is the active server or has broken trust; no repair was attempted.'
                    }
                    foreach ($name in @('RpcSs', 'Winmgmt', 'LanmanServer', 'WinRM')) {
                        if ((Get-Service -Name $name -ErrorAction Stop).Status -ne 'Running') {
                            throw "Required existing destination service '$name' is not Running; no service was changed."
                        }
                    }
                    $share = $null
                    try { $share = Get-SmbShare -Name $Identity.SiteCode -ErrorAction Stop }
                    catch { if ($_.CategoryInfo.Category -ne 'ObjectNotFound') { throw } }
                    $root = "E:\$($Identity.SiteCode)"
                    if ($share) { $root = "$($share.Path)" }
                    $folder = Join-Path $root 'ContentLib'
                    $folder = [IO.Path]::GetFullPath($folder).TrimEnd('\')
                    foreach ($reference in @($References)) {
                        if ($reference.ComputerName -ine $computer.Name) { continue }
                        $otherPath = "$($reference.Location)"
                        if ($otherPath -match '^\\\\[^\\]+\\([^\\]+)(?:\\(.*))?$') {
                            $otherShare = Get-SmbShare -Name $Matches[1] -ErrorAction Stop
                            $relative = "$($Matches[2])"
                            $otherPath = Join-Path $otherShare.Path $relative
                        }
                        $otherPath = [IO.Path]::GetFullPath($otherPath).TrimEnd('\')
                        if ($folder -ieq $otherPath -or $folder.StartsWith("$otherPath\", [StringComparison]::OrdinalIgnoreCase) -or
                            $otherPath.StartsWith("$folder\", [StringComparison]::OrdinalIgnoreCase)) {
                            throw "Selected destination filesystem overlaps source/other site '$($reference.SiteCode)'."
                        }
                    }
                    $marker = Join-Path $root 'MemLabs.ContentLibrary.reservation.json'
                    $reservation = $null
                    if (Test-Path -LiteralPath $marker -PathType Leaf) {
                        $reservation = Get-Content -LiteralPath $marker -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                        if ($reservation.SchemaVersion -ne 1 -or $reservation.OwnerVMName -ine $Identity.OwnerVMName -or
                            $reservation.SiteCode -ine $Identity.SiteCode -or $reservation.Destination -ine $Identity.Destination) {
                            throw 'Selected library directory is reserved by a different owner/site/destination.'
                        }
                    }
                    foreach ($path in @($root, $folder)) {
                        if (Test-Path -LiteralPath $path) {
                            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
                            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                                throw "Selected library path '$path' is not an ordinary directory."
                            }
                        }
                        $ancestor = [IO.Path]::GetDirectoryName($folder)
                        for ($depth = 0; $ancestor -and $depth -lt 128; $depth++) {
                            if (Test-Path -LiteralPath $ancestor) {
                                if ((Get-Item -LiteralPath $ancestor -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                                    throw 'Destination traverses an existing reparse point; no library request was submitted.'
                                }
                            }
                            $parent = [IO.Path]::GetDirectoryName($ancestor)
                            if ($parent -eq $ancestor) { break }
                            $ancestor = $parent
                        }
                    }
                    $populated = (Test-Path -LiteralPath $folder) -and
                        @(Get-ChildItem -LiteralPath $folder -Force -ErrorAction Stop).Count -gt 0
                    if ($CreateReservation) {
                        if ($populated -or $reservation) {
                            throw 'A new native library request requires a NEW/EMPTY, unclaimed destination; populated/prior reservations are never adopted or retried.'
                        }
                        if (-not $share -and (Test-Path -LiteralPath $root) -and
                            @(Get-ChildItem -LiteralPath $root -Force -ErrorAction Stop).Count) {
                            throw 'Cannot create the reserved site share over an existing populated directory.'
                        }
                        if (-not (Test-Path -LiteralPath 'E:\' -PathType Container) -and -not $share) {
                            throw 'Required destination volume E: is absent; no disk/volume repair was attempted.'
                        }
                        $null = New-Item -Path $folder -ItemType Directory -Force -ErrorAction Stop
                        # Claim the new destination before granting either principal access.
                        # The sidecar survives native removal of extra files in ContentLib.
                        $null = New-Item -Path $marker -ItemType File -ErrorAction Stop
                        $Identity | ConvertTo-Json -Compress -ErrorAction Stop |
                            Set-Content -LiteralPath $marker -Encoding UTF8 -ErrorAction Stop
                        if (-not $share) {
                            $null = New-SmbShare -Name $Identity.SiteCode -Path $root `
                                -FullAccess @($Active.AccountName, $Passive.AccountName) -ErrorAction Stop
                        }
                        $access = @(Get-SmbShareAccess -Name $Identity.SiteCode -ErrorAction Stop)
                        $acl = Get-Acl -LiteralPath $folder -ErrorAction Stop
                        if (@($access | Where-Object AccessControlType -eq 'Deny').Count -or
                            @($acl.Access | Where-Object AccessControlType -eq 'Deny').Count) {
                            throw 'Destination has an existing deny policy; no ACL policy was reset.'
                        }
                        foreach ($principal in @($Active, $Passive)) {
                            if (-not @($access | Where-Object {
                                        $_.AccountName -ieq $principal.AccountName -and $_.AccessControlType -eq 'Allow' -and $_.AccessRight -eq 'Full'
                                    }).Count) {
                                Grant-SmbShareAccess -Name $Identity.SiteCode -AccountName $principal.AccountName -AccessRight Full -Force -ErrorAction Stop | Out-Null
                            }
                            $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
                            if (-not @($rules | Where-Object {
                                        "$($_.IdentityReference)" -eq $principal.Sid -and $_.AccessControlType -eq 'Allow' -and
                                        ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl
                                    }).Count) {
                                $inherit = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
                                $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                                        [Security.Principal.SecurityIdentifier]::new($principal.Sid),
                                        [Security.AccessControl.FileSystemRights]::FullControl, $inherit,
                                        [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
                                Set-Acl -LiteralPath $folder -AclObject $acl -ErrorAction Stop
                            }
                        }
                    }
                    [pscustomobject]@{ ComputerName = "$($computer.Name)"; Folder = $folder; Populated = [bool]$populated }
                }
        }

        function Invoke-ScopedLibraryRelocation {
            param($Target, [string]$Destination, $ActivePrincipal, $PassivePrincipal)
            $mutex = [Threading.Mutex]::new($false, "Global\MemLabs.ContentLibrary.$($ThisVM.vmName).$($Payload.SiteCode)")
            $locked = $false
            $submitted = $false
            $abandoned = $false
            try {
                try { $locked = $mutex.WaitOne([TimeSpan]::FromSeconds(30)) }
                catch [Threading.AbandonedMutexException] { $locked = $true; $abandoned = $true }
                if (-not $locked) { throw 'Timed out acquiring the bounded owner/site content-library request lock; no lease was broken.' }
                $state = Get-ScopedLibraryNativeState
                Assert-ScopedLibraryCollisionFree -State $state -Destination $Destination
                $dest = Get-ScopedLibraryPathKey $Destination
                $selected = (Get-ScopedLibraryPathKey $state.Location) -eq $dest
                if ($state.Result -notin @(0, 131077, 131078)) {
                    throw "Required existing library prerequisite failed with Result=$($state.Result); no missing-library/update/baseline repair was attempted."
                }
                if ($state.Result -eq 131078 -and -not $selected) {
                    throw 'A different or unattributable site content-library move is pending; it was not resubmitted or cancelled.'
                }
                if (-not $selected) {
                    if ($abandoned) { throw 'Previous owner action abandoned its lock; no new native request is retried without attributable selected-destination state.' }
                    $source = Get-ScopedLibraryPathKey $state.Path
                    if (-not $source -or $source -eq $dest -or $source.StartsWith("$dest\") -or $dest.StartsWith("$source\")) {
                        throw 'Content-library source and destination are not provably disjoint.'
                    }
                    if ($state.Location -and (Get-ScopedLibraryPathKey $state.Location) -ne $source) {
                        throw 'Existing native location and active-server pointer show an unfinished different cutover; no new request was submitted.'
                    }
                    $sourceHealth = Invoke-CMRoleTargetCommand -ComputerName (Get-ScopedFqdn $ThisVM.vmName) `
                        -ArgumentList @($state.Path) -ScriptBlock {
                            param([string]$Source)
                            $item = Get-Item -LiteralPath "FileSystem::$Source" -Force -ErrorAction Stop
                            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                                throw 'Current content-library source is not an ordinary readable directory.'
                            }
                            $ancestor = [IO.Path]::GetDirectoryName($Source.TrimEnd('\'))
                            for ($depth = 0; $ancestor -and $depth -lt 128; $depth++) {
                                $parentItem = Get-Item -LiteralPath "FileSystem::$ancestor" -Force -ErrorAction Stop
                                if ($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                                    throw 'Current source traverses a reparse point; disjoint relocation cannot be proved.'
                                }
                                $next = [IO.Path]::GetDirectoryName($ancestor)
                                if ($next -eq $ancestor) { break }
                                $ancestor = $next
                            }
                            $null = Get-ChildItem -LiteralPath "FileSystem::$Source" -Force -ErrorAction Stop
                            [pscustomobject]@{ Ready = $true }
                        }
                    if (-not $sourceHealth.Ready) { throw 'Current content-library source health could not be verified; no source repair was attempted.' }
                    Assert-ScopedBudget
                    $null = Invoke-ScopedLibraryDestination -Target $Target -Destination $Destination `
                        -ActivePrincipal $ActivePrincipal -PassivePrincipal $PassivePrincipal -Reserve -State $state
                    Assert-ScopedBudget
                    $reply = Invoke-CimMethod -Namespace "root\SMS\site_$($Payload.SiteCode)" -ClassName SMS_Site `
                        -MethodName SetContentLibraryLocation -Arguments @{ SiteCode = "$($Payload.SiteCode)"; Location = $Destination } `
                        -OperationTimeoutSec 30 -ErrorAction Stop
                    if ($null -eq $reply.ReturnValue -or [int]$reply.ReturnValue -ne 0) {
                        throw "SetContentLibraryLocation failed with ReturnValue='$($reply.ReturnValue)'; it was not retried."
                    }
                    $submitted = $true
                    Write-DscStatus "Submitted exact-site content-library relocation to '$Destination'. Native copying can pause site package processing; submission is not completion."
                }
                else {
                    $null = Invoke-ScopedLibraryDestination -Target $Target -Destination $Destination `
                        -ActivePrincipal $ActivePrincipal -PassivePrincipal $PassivePrincipal -State $state
                }
                $null = Wait-ScopedObservation -Seconds 5400 -Description "content-library exact-site/native-pointer/prerequisite cutover to '$Destination'" -Probe {
                    $current = Get-ScopedLibraryNativeState
                    Assert-ScopedLibraryCollisionFree -State $current -Destination $Destination
                    if ($current.Result -notin @(0, 131077, 131078)) {
                        throw "Content-library move is unfinished/failed (Result=$($current.Result)); no cancellation, retry or reinitialization was requested."
                    }
                    $ready = (Get-ScopedLibraryPathKey $current.Location) -eq $dest -and
                        (Get-ScopedLibraryPathKey $current.Path) -eq $dest -and
                        (Get-ScopedLibraryPathKey $current.Drives) -eq $dest -and $current.Result -eq 0
                    [pscustomobject]@{
                        Ready = $ready
                        Detail = "exact-site location='$($current.Location)', native path='$($current.Path)', native usable drives='$($current.Drives)', Result=$($current.Result)"
                    }
                }
            }
            catch { throw "Content-library relocation was not certified complete (submitted=$submitted): $($_.Exception.Message) Native work, if submitted, is left running without cancellation/reinit." }
            finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
        }

        function Invoke-ScopedPassive {
            param($Target)
            $fqdn = Get-ScopedFqdn $Target.vmName
            $nodes = @(Get-WmiObject -Namespace "root\SMS\site_$($Payload.SiteCode)" -Class SMS_SCI_SysResUse `
                    -Filter "RoleName = 'SMS Site Server' AND SiteCode = '$($Payload.SiteCode)' AND SiteSystemStatus = 0" -ErrorAction Stop |
                    Where-Object { $null -ne $_ })
            if ($nodes.Count -gt 1 -or @($nodes | Where-Object { "$($_.NetworkOSPath)".TrimStart('\') -ine $fqdn }).Count) {
                throw "Site '$($Payload.SiteCode)' already has a conflicting passive site server; no object was changed."
            }
            $provisionNewBindings = $Target.IsNewTarget -eq $true -and $nodes.Count -eq 0
            $null = Get-ScopedSite -Code $Payload.SiteCode
            $libraryVM = Get-ScopedConfigVM -Name $Target.remoteContentLibVM
            $libraryFqdn = Get-ScopedFqdn $libraryVM.vmName
            $libraryPath = "\\$($libraryVM.vmName)\$($Payload.SiteCode)\ContentLib"
            if ($libraryVM.vmName -ieq $ThisVM.vmName -or $libraryVM.vmName -ieq $Target.vmName) {
                throw 'Selected remote content library cannot be the active or passive site-server VM.'
            }
            if (@(Get-CMDistributionPoint -SiteSystemServerName (Get-ScopedFqdn $ThisVM.vmName) -SiteCode $Payload.SiteCode -ErrorAction Stop | Where-Object { $null -ne $_ }).Count) {
                throw "Required active-site prerequisite for passive '$fqdn': '$($ThisVM.vmName)' still hosts a DP, which prevents a remote site content library. Removing an existing DP is not authorized; no DP was removed."
            }
            $libraryState = Get-ScopedLibraryNativeState
            Assert-ScopedLibraryCollisionFree -State $libraryState -Destination $libraryPath
            $destKey = Get-ScopedLibraryPathKey $libraryPath
            $libraryTransition = (Get-ScopedLibraryPathKey $libraryState.Location) -ne $destKey -or
                (Get-ScopedLibraryPathKey $libraryState.Path) -ne $destKey -or
                (Get-ScopedLibraryPathKey $libraryState.Drives) -ne $destKey -or $libraryState.Result -ne 0
            if ($libraryState.Result -notin @(0, 131077, 131078)) {
                throw "Required existing library failed site-specific prerequisite Result=$($libraryState.Result); no baseline repair was attempted."
            }
            if ($libraryState.Result -eq 131078 -and (Get-ScopedLibraryPathKey $libraryState.Location) -ne $destKey) {
                throw 'A different or unattributable content-library move is pending; no request was submitted or retried.'
            }
            if (-not $libraryTransition) {
                $null = Invoke-ScopedLibraryDestination -Target $Target -Destination $libraryPath -State $libraryState
            }
            if (-not $ThisVM.remoteSQLVM -or $ThisVM.remoteSQLVM -ieq $ThisVM.vmName -or $ThisVM.remoteSQLVM -ieq $Target.vmName) {
                throw "Passive '$fqdn' requires an existing remote site SQL server. No database relocation was attempted."
            }
            $passiveAccount = "$NetbiosDomainName\$($Target.vmName)`$"
            $activeAccount = "$NetbiosDomainName\$($ThisVM.vmName)`$"
            $activePrincipal = $null
            $newPrincipal = $null
            $sqlBinding = $null
            if ($provisionNewBindings) {
                Assert-ScopedSql -SiteVM $ThisVM -RequiredLogins @($activeAccount)
                $activePrincipal = Get-ScopedComputerPrincipal -Name $ThisVM.vmName
                $newPrincipal = Get-ScopedComputerPrincipal -Name $Target.vmName
                $oldSqlBinding = Invoke-ScopedSqlComputerBinding -Principal $activePrincipal
                if ($oldSqlBinding.NeedsGrant) { throw "Required existing active computer SQL binding is missing; no old principal was repaired." }
                $sqlBinding = Invoke-ScopedSqlComputerBinding -Principal $newPrincipal
            }
            else { Assert-ScopedSql -SiteVM $ThisVM -RequiredLogins @($activeAccount, $passiveAccount) }
            $systems = @(Get-CMSiteSystemServer -SiteCode $Payload.SiteCode -ErrorAction Stop | Where-Object { $null -ne $_ })
            $dependencyNames = @((Get-ScopedFqdn $ThisVM.vmName), (Get-ScopedFqdn $ThisVM.remoteSQLVM))
            if (-not $libraryTransition) { $dependencyNames += $libraryFqdn }
            $sqlVM = Get-ScopedConfigVM -Name $ThisVM.remoteSQLVM
            if ($sqlVM.AlwaysOnListenerName -or $sqlVM.role -eq 'SQLAO') {
                $sqlPartner = Get-ScopedConfigVM -Name $sqlVM.OtherNode
                $dependencyNames += Get-ScopedFqdn $sqlPartner.vmName
            }
            foreach ($system in $systems) {
                $name = "$($system.NetworkOSPath)".TrimStart('\')
                if (-not $name -or $name -match '[\\/:]') { throw "Required site-system identity is invalid in site '$($Payload.SiteCode)'." }
                $dependencyNames += $name
            }
            $adminBindings = [Collections.Generic.List[object]]::new()
            foreach ($name in @($dependencyNames | Sort-Object -Unique)) {
                if ($name -ieq $fqdn) { continue }
                if ($provisionNewBindings) {
                    $binding = Invoke-ScopedPassiveAdminBinding -ComputerName $name -ActivePrincipal $activePrincipal -NewPrincipal $newPrincipal
                    $adminBindings.Add([pscustomobject]@{ ComputerName = $name; NeedsGrant = $binding.NeedsGrant })
                    continue
                }
                $state = Get-ScopedAdminState -ComputerName $name -Accounts @($passiveAccount)
                if (-not $state.Ready) {
                    throw "Required passive prerequisite on retained '$name': $($state.Detail). No local-admin grants were changed."
                }
            }
            $libraryBinding = $null
            if (-not $libraryTransition -and $provisionNewBindings) {
                $libraryBinding = Invoke-ScopedPassiveLibraryBinding -ComputerName $libraryFqdn `
                    -ActivePrincipal $activePrincipal -NewPrincipal $newPrincipal
            }
            elseif (-not $libraryTransition) {
            $libraryState = Invoke-CMRoleTargetCommand -ComputerName $libraryFqdn `
                -ArgumentList @("$($Payload.SiteCode)", @($activeAccount, $passiveAccount)) -ScriptBlock {
                    param([string]$ShareName, [string[]]$Accounts)
                    $ErrorActionPreference = 'Stop'
                    $share = Get-SmbShare -Name $ShareName -ErrorAction Stop
                    $folder = Join-Path $share.Path 'ContentLib'
                    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { throw "Content library directory '$folder' is missing." }
                    $shareAccess = @(Get-SmbShareAccess -Name $ShareName -ErrorAction Stop)
                    $acl = Get-Acl -LiteralPath $folder -ErrorAction Stop
                    foreach ($account in $Accounts) {
                        $shareGrant = @($shareAccess | Where-Object {
                                $_.AccountName -ieq $account -and $_.AccessControlType -eq 'Allow' -and $_.AccessRight -eq 'Full'
                            })
                        $ntfsGrant = @($acl.Access | Where-Object {
                                "$($_.IdentityReference)" -ieq $account -and $_.AccessControlType -eq 'Allow' -and
                                ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl
                            })
                        $denies = @($shareAccess | Where-Object { $_.AccessControlType -eq 'Deny' })
                        $denies += @($acl.Access | Where-Object { $_.AccessControlType -eq 'Deny' })
                        if (-not $shareGrant.Count -or -not $ntfsGrant.Count -or $denies.Count) {
                            throw "Cannot prove existing share/NTFS FullControl without denies for '$account' on '$folder'."
                        }
                    }
                    [pscustomobject]@{ Ready = $true }
                }
            if (-not $libraryState.Ready) { throw "Required retained library '$libraryFqdn' access could not be verified; no ACL was changed." }
            }
            $state = Get-ScopedAdminState -ComputerName $fqdn -Accounts @($activeAccount)
            if (-not $state.Ready) { throw "Required active-site access on requested passive '$fqdn' failed ($($state.Detail)). No account grants were changed." }
            if ($nodes.Count -eq 0) {
            $null = Wait-ScopedObservation -RetryReadErrors -Description "Phase 8 ADK preparation on requested passive '$fqdn'" -Probe {
                Invoke-CMRoleTargetCommand -ComputerName $fqdn -ScriptBlock {
                    $missing = @()
                    $root = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit'
                    foreach ($feature in @('Deployment Tools', 'Windows Preinstallation Environment')) {
                        $path = Join-Path $root $feature
                        if (-not (Test-Path -LiteralPath $path -PathType Container -ErrorAction Stop)) { $missing += $path }
                    }
                    [pscustomobject]@{ Ready = $missing.Count -eq 0; Detail = "ADK missing [$($missing -join ', ')]" }
                }
            }
            if ($usePKI) {
                $null = Wait-ScopedObservation -Description "Phase 8 IIS HTTPS preparation on requested passive '$fqdn'" -Probe {
                    [pscustomobject]@{ Ready = (Test-MPHttpsBinding -MPFQDN $fqdn); Detail = 'valid requested-passive IIS HTTPS binding is required' }
                }
            }
            }
            if ($libraryTransition) {
                if (-not $activePrincipal) { $activePrincipal = Get-ScopedComputerPrincipal -Name $ThisVM.vmName }
                if (-not $newPrincipal) { $newPrincipal = Get-ScopedComputerPrincipal -Name $Target.vmName }
                Invoke-ScopedLibraryRelocation -Target $Target -Destination $libraryPath `
                    -ActivePrincipal $activePrincipal -PassivePrincipal $newPrincipal
                $libraryBinding = Invoke-ScopedPassiveLibraryBinding -ComputerName $libraryFqdn `
                    -ActivePrincipal $activePrincipal -NewPrincipal $newPrincipal
            }
            if ($nodes.Count -eq 1) {
                Wait-ScopedPassiveReady -Fqdn $fqdn
                return
            }
            if ($provisionNewBindings) {
                if ($sqlBinding.NeedsGrant) { $null = Invoke-ScopedSqlComputerBinding -Principal $newPrincipal -Apply }
                foreach ($binding in $adminBindings) {
                    if ($binding.NeedsGrant) {
                        $null = Invoke-ScopedPassiveAdminBinding -ComputerName $binding.ComputerName `
                            -ActivePrincipal $activePrincipal -NewPrincipal $newPrincipal -Apply
                    }
                }
                if ($libraryBinding.NeedsGrant) {
                    $null = Invoke-ScopedPassiveLibraryBinding -ComputerName $libraryFqdn `
                        -ActivePrincipal $activePrincipal -NewPrincipal $newPrincipal -Apply
                    $verified = Invoke-ScopedPassiveLibraryBinding -ComputerName $libraryFqdn `
                        -ActivePrincipal $activePrincipal -NewPrincipal $newPrincipal
                    if ($verified.NeedsGrant) { throw "New passive computer library binding did not verify; no old ACL was repaired." }
                }
            }
            $null = Initialize-ScopedSiteSystem -Fqdn $fqdn -Code $Payload.SiteCode
            $directory = 'C:\Program Files\Microsoft Configuration Manager'
            if ($Target.cmInstallDir) { $directory = "$($Target.cmInstallDir)" }
            Assert-ScopedBudget
            $null = Add-CMPassiveSite -InstallDirectory $directory -SiteCode $Payload.SiteCode `
                -SiteSystemServerName $fqdn -SourceFilePathOption CopySourceFileFromActiveSite -ErrorAction Stop
            Wait-ScopedPassiveReady -Fqdn $fqdn
        }

        function Get-ScopedProviderLocations {
            param([string]$Fqdn)
            return @(Get-CimInstance -Namespace 'root\SMS' -ClassName SMS_ProviderLocation `
                    -Filter "SiteCode='$($Payload.SiteCode)'" -OperationTimeoutSec 30 -ErrorAction Stop |
                    Where-Object { "$($_.Machine)".TrimStart('\').TrimEnd('.') -ieq $Fqdn })
        }

        function Assert-ScopedProviderPreservation {
            param($Target)
            $fqdn = Get-ScopedFqdn $Target.vmName
            # release_2609 setup\newsetup\modify.cpp routes provider addition
            # through shared site maintenance. No setup switch makes it scoped.
            try {
                $locations = @(Get-ScopedProviderLocations -Fqdn $fqdn)
                if ($locations.Count -ne 1 -or $locations[0].SiteCode -ine $Payload.SiteCode) {
                    throw "Expected one existing exact-target SMS_ProviderLocation for this site; found $($locations.Count)."
                }
                $providerSite = @(Get-CimInstance -ComputerName $fqdn -Namespace "root\SMS\site_$($Payload.SiteCode)" `
                        -ClassName SMS_Site -Filter "SiteCode='$($Payload.SiteCode)'" -OperationTimeoutSec 30 -ErrorAction Stop |
                        Where-Object { $null -ne $_ })
                if ($providerSite.Count -ne 1 -or $providerSite[0].SiteCode -ine $Payload.SiteCode -or
                    $providerSite[0].Status -ne 1) {
                    throw "The existing exact-target provider cannot read Active site '$($Payload.SiteCode)'."
                }
            }
            catch {
                throw "Product-safety blocker for requested SMS Provider '$fqdn' in site '$($Payload.SiteCode)': $($_.Exception.Message) Native provider addition requires broader site maintenance and cannot be run under preservation policy. Automatic provider setup/repair was not attempted."
            }
        }

        $targets = @($Payload.Targets)
        $targetNames = @{}
        foreach ($target in $targets) {
            if (-not $target.vmName -or "$($target.vmName)" -notmatch '^[a-zA-Z0-9][a-zA-Z0-9-]*$' -or
                "$($target.siteCode)" -notmatch '^[a-zA-Z0-9]{3}$' -or $targetNames.ContainsKey("$($target.vmName)")) {
                throw 'Invalid/duplicate SiteRoles target identity.'
            }
            $targetNames["$($target.vmName)"] = $true
            $configured = Get-ScopedConfigVM -Name $target.vmName
            if ($configured.hidden -eq $true -and $configured.ExistingVM -ne $true) {
                throw "SiteRoles target '$($target.vmName)' is dependency context, not a requested deployment target."
            }
            if (($target.IsNewTarget -eq $true) -ne (-not $configured.hidden -and $configured.ExistingVM -ne $true)) {
                throw "SiteRoles target '$($target.vmName)' changed its new/existing ownership after planning."
            }
            if ("$($target.ConfiguredSiteCode)" -ine "$($configured.siteCode)") { throw "SiteRoles target '$($target.vmName)' changed 'siteCode' after planning." }
            if ($target.siteCode -ine $configured.siteCode -and
                -not (-not $configured.siteCode -and $ThisVM.remoteSQLVM -ieq $target.vmName -and
                    $target.siteCode -ieq $Payload.SiteCode -and ($target.installRP -or $target.installSMSProv) -and
                    -not ($target.installDP -or $target.installMP -or $target.installSUP))) {
                throw "SiteRoles target '$($target.vmName)' has no explicit, uniquely owned role site."
            }
            foreach ($property in @('role', 'parentSiteCode', 'siteName', 'pullDPSourceDP', 'remoteContentLibVM',
                    'cmInstallDir', 'sqlVersion', 'sqlInstanceName', 'sqlPort')) {
                if ("$($target.$property)" -ine "$($configured.$property)") { throw "SiteRoles target '$($target.vmName)' changed '$property' after planning." }
            }
            foreach ($property in @('installDP', 'enablePullDP', 'installMP', 'installSUP', 'installRP', 'installSMSProv')) {
                if (($target.$property -eq $true) -ne ($configured.$property -eq $true)) { throw "SiteRoles target '$($target.vmName)' changed '$property' after planning." }
            }
            if ($target.role -in @('Primary', 'CAS') -or $target.vmName -ieq $Payload.OwnerVMName) {
                throw "SiteRoles cannot reassert owning/existing site server '$($target.vmName)'."
            }
            if ($target.role -eq 'Secondary') {
                if ($target.parentSiteCode -ine $Payload.SiteCode) { throw "Secondary '$($target.vmName)' has a different owning Primary." }
                if ($target.installRP -or $target.installSMSProv -or $target.enablePullDP) {
                    throw "Secondary '$($target.vmName)' cannot host RP/additional SMS Provider/pull-DP roles."
                }
            }
            elseif ($target.siteCode -ine $Payload.SiteCode) {
                $secondary = @($deployConfig.virtualMachines | Where-Object {
                        $_ -and $_.role -eq 'Secondary' -and $_.siteCode -ieq $target.siteCode -and $_.parentSiteCode -ieq $Payload.SiteCode
                    })
                if ($secondary.Count -ne 1 -or $target.role -eq 'PassiveSite') { throw "Target '$($target.vmName)' is outside owner site '$($Payload.SiteCode)'." }
                if ($target.installMP -or $target.installSUP -or $target.installRP -or $target.installSMSProv) {
                    throw "Remote site-system '$($target.vmName)' in secondary '$($target.siteCode)' can only add the supported DP role; MP/SUP must be on the secondary site server."
                }
            }
            if ($target.role -eq 'PassiveSite' -and
                ($target.installDP -or $target.installMP -or $target.installSUP -or $target.installRP -or $target.installSMSProv)) {
                throw "Passive site server '$($target.vmName)' cannot cohost additional site-system roles."
            }
        }
        foreach ($target in @($targets | Where-Object { $_.installSMSProv })) {
            Assert-ScopedProviderPreservation -Target $target
        }
        $ownerSite = Get-ScopedSite -Code $Payload.SiteCode
        if ($ownerSite.Type -ne 2 -or $ownerSite.Status -ne 1 -or
            "$($ownerSite.ServerName)".TrimStart('\') -ine (Get-ScopedFqdn $ThisVM.vmName)) {
            throw "Required existing Primary '$($Payload.SiteCode)' is not Active on '$($ThisVM.vmName)'; no site repair was attempted."
        }
        foreach ($name in @('SMS_EXECUTIVE', 'SMS_SITE_COMPONENT_MANAGER')) {
            $service = Get-Service -Name $name -ErrorAction Stop
            if ($service.Status -ne 'Running') { throw "Required existing Primary service '$name' is '$($service.Status)'; no service was started/restarted." }
        }
        Assert-ScopedSql -SiteVM $ThisVM
        $options = if ($ThisVM.cmOptions) { $ThisVM.cmOptions } else { $deployConfig.cmOptions }
        $usePKI = $options.UsePKI -eq $true
        foreach ($target in @($targets | Where-Object { $_.role -eq 'Secondary' })) {
            $null = Invoke-ScopedSecondary -Target $target
        }
        foreach ($target in @($targets | Where-Object { $_.role -ne 'Secondary' -and $_.siteCode -ine $Payload.SiteCode })) {
            $site = Get-ScopedSite -Code $target.siteCode
            if ($site.Type -ne 1 -or $site.ReportingSiteCode -ine $Payload.SiteCode -or $site.Status -ne 1) {
                throw "Required existing secondary '$($target.siteCode)' is not Active under '$($Payload.SiteCode)'; no parent/site recovery was attempted."
            }
        }
        foreach ($role in @('DP', 'MP', 'SUP', 'RP')) {
            $property = "install$role"
            $orderedTargets = @($targets | Sort-Object @{ Expression = { [bool]$_.enablePullDP } }, vmName)
            foreach ($target in $orderedTargets) {
                if (-not $target.$property -or $target.role -eq 'PassiveSite' -or
                    ($target.role -eq 'Secondary' -and $role -in @('DP', 'MP'))) { continue }
                $null = Invoke-ScopedRoleAddition -Target $target -Role $role
            }
        }
        Write-DscStatus "SiteRoles requested targets: $(($targets | ForEach-Object { "$($_.vmName):$($_.role):DP=$($_.installDP):MP=$($_.installMP):SUP=$($_.installSUP):RP=$($_.installRP):Provider=$($_.installSMSProv)" }) -join '; ')."
        foreach ($target in @($targets | Where-Object {
                    $_.role -eq 'SiteSystem' -and -not ($_.installDP -or $_.installMP -or $_.installSUP -or $_.installRP -or $_.installSMSProv)
                })) {
            $null = Initialize-ScopedSiteSystem -Fqdn (Get-ScopedFqdn $target.vmName) -Code $target.siteCode
        }
        foreach ($target in @($targets | Where-Object { $_.role -eq 'PassiveSite' })) {
            $null = Invoke-ScopedPassive -Target $target
        }
        foreach ($target in @($targets | Where-Object { $_.installSMSProv })) {
            Assert-ScopedProviderPreservation -Target $target
        }
        return @{ Status = 'Completed'; TargetVMNames = @($targets | ForEach-Object { "$($_.vmName)" }) }
    }

    foreach ($group in @($groups.Values | Sort-Object { $_.Owner.siteCode }, { $_.Owner.vmName })) {
        $targets = @($group.Targets | Sort-Object vmName)
        [pscustomobject]@{
            Kind = 'SiteRoles'
            OwnerVMName = "$($group.Owner.vmName)"
            SiteCode = "$($group.Owner.siteCode)"
            TargetVMNames = @($targets | ForEach-Object { "$($_.vmName)" })
            Payload = ([ordered]@{
                    Version = 1; OwnerVMName = "$($group.Owner.vmName)"; SiteCode = "$($group.Owner.siteCode)"; Targets = $targets
                } | ConvertTo-Json -Depth 20 -Compress -ErrorAction Stop)
            Handler = $handler
            TimeoutSeconds = 7200
        }
    }
}
