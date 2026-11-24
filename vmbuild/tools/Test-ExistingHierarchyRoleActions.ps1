<#
.SYNOPSIS
    Executes the shipped scoped-role planner/guest handler without native actions.
.EXAMPLE
    pwsh -NoProfile -File .\vmbuild\tools\Test-ExistingHierarchyRoleActions.ps1 -Mode Plan
.EXAMPLE
    powershell -NoProfile -File .\vmbuild\tools\Test-ExistingHierarchyRoleActions.ps1 -Mode Handler
#>
[CmdletBinding()]
param(
    [string]$RootPath,
    [ValidateSet('All', 'Plan', 'Handler')][string]$Mode = 'All'
)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
. (Join-Path $RootPath 'common\Common.ExistingHierarchy.Roles.ps1')
. (Join-Path $RootPath 'common\Common.ExistingHierarchy.ps1')
foreach ($entry in @(
        @{ Path = 'common\Common.Config.ps1'; Name = 'Add-VMToAccountLists' },
        @{ Path = 'DSC\phases\ScriptFunctions.ps1'; Name = 'Assert-MemLabsSelectedSupPrerequisite' }
    )) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $RootPath $entry.Path), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Cannot load role fixture contract '$($entry.Name)'." }
    $name = $entry.Name
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
$script:Assertions = 0
$script:Cases = 0

function Assert-RoleTest {
    param([bool]$Condition, [string]$Message)
    $script:Assertions++
    if (-not $Condition) { throw $Message }
}
function Assert-RoleThrows {
    param([scriptblock]$ScriptBlock, [string]$Pattern)
    $caught = $null
    try { $null = & $ScriptBlock } catch { $caught = $_ }
    Assert-RoleTest ($null -ne $caught) "Expected blocker '$Pattern', but the action succeeded."
    Assert-RoleTest ("$($caught.Exception.Message)" -like $Pattern) "Wrong blocker: '$($caught.Exception.Message)'; expected '$Pattern'."
}

# These are the parent's host-only contracts, not functions available in a guest.
function Test-MemLabsContextOnlyVM {
    param($VM)
    return $VM.hidden -eq $true -and $VM.ExistingVM -ne $true -and $VM.cmOptionsChanged -ne $true
}
function Get-MemLabsRequestedDeploymentVMs {
    param($DeployConfig)
    $DeployConfig.virtualMachines | Where-Object { $_ -and (-not $_.hidden -or $_.ExistingVM -eq $true -or $_.cmOptionsChanged -eq $true) }
}
function Resolve-MemLabsDeploymentPrimary {
    param($DeployConfig, [string]$SiteCode)
    $sites = @($DeployConfig.virtualMachines | Where-Object { $_ -and $_.role -in @('Primary', 'Secondary') -and $_.siteCode -ieq $SiteCode })
    if ($sites.Count -eq 1 -and $sites[0].role -eq 'Secondary') {
        $parent = "$($sites[0].parentSiteCode)"
        $sites = @($DeployConfig.virtualMachines | Where-Object { $_ -and $_.role -eq 'Primary' -and $_.siteCode -ieq $parent })
    }
    if ($sites.Count -ne 1 -or $sites[0].role -ne 'Primary') { throw "Cannot resolve one Primary owner for deployment site '$SiteCode'." }
    return $sites[0]
}
function New-RoleTestVM {
    param([string]$Name = 'NEW-ROLE', [string]$Role = 'SiteSystem', [hashtable]$Properties = @{})
    $value = [ordered]@{ vmName = $Name; role = $Role; siteCode = 'PRI' }
    foreach ($key in $Properties.Keys) { $value[$key] = $Properties[$key] }
    [pscustomobject]$value
}
function New-RoleTestConfig {
    param([object[]]$Targets = @())
    [pscustomobject]@{
        vmOptions = [pscustomobject]@{ domainName = 'lab.test'; domainNetBiosName = 'LAB' }
        cmOptions = [pscustomobject]@{ Install = $false; UsePKI = $false }
        virtualMachines = @(
            (New-RoleTestVM -Name 'OLD-PRI' -Role Primary -Properties @{
                    hidden = $true; remoteSQLVM = 'OLD-SQL'; installDP = $true; installMP = $true; installSUP = $true
                }),
            (New-RoleTestVM -Name 'OLD-SQL' -Role SqlServer -Properties @{
                    hidden = $true; sqlInstanceName = 'MSSQLSERVER'; sqlPort = 5422; installRP = $true
                }),
            (New-RoleTestVM -Name 'OLD-BROKEN' -Properties @{
                    hidden = $true; installDP = $true; installMP = $true; installSUP = $true; installRP = $true; installSMSProv = $true
                }),
            (New-RoleTestVM -Name 'OLD-LIB' -Role FileServer -Properties @{ hidden = $true })
        ) + $Targets
    }
}

if ($Mode -in @('All', 'Plan')) {
    foreach ($family in @(
            @{ Role = 'SiteSystem'; Properties = @{} },
            @{ Role = 'SiteSystem'; Properties = @{ installDP = $true; installMP = $true; installSUP = $true; installRP = $true; installSMSProv = $true } },
            @{ Role = 'WSUS'; Properties = @{ installSUP = $true } },
            @{ Role = 'Secondary'; Properties = @{ siteCode = 'SEC'; parentSiteCode = 'PRI' } },
            @{ Role = 'PassiveSite'; Properties = @{ remoteContentLibVM = 'OLD-LIB' } }
        )) {
        $config = New-RoleTestConfig -Targets @((New-RoleTestVM -Role $family.Role -Properties $family.Properties))
        $before = $config | ConvertTo-Json -Depth 30 -Compress
        $plan = @(Get-MemLabsExistingRoleActions -DeployConfig $config)
        Assert-RoleTest ($plan.Count -eq 1) "Planner omitted supported $($family.Role) addition."
        Assert-RoleTest ($plan[0].OwnerVMName -eq 'OLD-PRI' -and $plan[0].SiteCode -eq 'PRI') 'Planner chose the wrong owning Primary.'
        Assert-RoleTest (@($plan[0].TargetVMNames).Count -eq 1 -and $plan[0].TargetVMNames[0] -eq 'NEW-ROLE') 'Planner expanded to an unrelated existing role.'
        Assert-RoleTest (($config | ConvertTo-Json -Depth 30 -Compress) -ceq $before) 'Planning changed deployConfig.'
        $script:Cases++
    }
    foreach ($intent in @('New', 'ExistingVM', 'cmOptionsChanged')) {
        $config = New-RoleTestConfig -Targets @((New-RoleTestVM -Properties @{ installSUP = $true }))
        if ($intent -eq 'New') { $config.virtualMachines[0].hidden = $false }
        else { $config.virtualMachines[0] | Add-Member -NotePropertyName $intent -NotePropertyValue $true }
        Assert-RoleTest (@(Get-MemLabsExistingRoleActions -DeployConfig $config).Count -eq 0) 'An explicitly requested owner was routed into a context actor.'
        $script:Cases++
    }
    foreach ($property in @('installSUP', 'installSMSProv', 'installRP')) {
        $targetProperties = @{ siteCode = 'CAS'; $property = $true }
        $config = New-RoleTestConfig -Targets @((New-RoleTestVM -Properties $targetProperties))
        $config.virtualMachines[0].role = 'CAS'
        $config.virtualMachines[0].siteCode = 'CAS'
        $config.virtualMachines[0].hidden = $false
        if ($property -eq 'installRP') {
            $config.virtualMachines[0].remoteSQLVM = 'NEW-ROLE'
            $config.virtualMachines[-1].PSObject.Properties.Remove('siteCode')
        }
        Assert-RoleTest (@(Get-MemLabsExistingRoleActions -DeployConfig $config).Count -eq 0) 'A new CAS remote role was rejected before its ordinary workflow.'
        $script:Cases++
    }
    $config = New-RoleTestConfig -Targets @(
        $null,
        (New-RoleTestVM -Name 'EDITED-DP' -Properties @{ hidden = $true; ExistingVM = $true; installDP = $true }),
        (New-RoleTestVM -Name 'OTHER-PRI' -Role Primary -Properties @{ siteCode = 'TWO'; hidden = $true }),
        (New-RoleTestVM -Name 'OTHER-DP' -Properties @{ siteCode = 'TWO'; installDP = $true }),
        (New-RoleTestVM -Name 'OLD-SEC' -Role Secondary -Properties @{ siteCode = 'SEC'; parentSiteCode = 'PRI'; hidden = $true }),
        (New-RoleTestVM -Name 'CHILD-DP' -Properties @{ siteCode = 'SEC'; installDP = $true })
    )
    $plans = @(Get-MemLabsExistingRoleActions -DeployConfig $config)
    $first = @($plans | Where-Object OwnerVMName -eq 'OLD-PRI')
    $second = @($plans | Where-Object OwnerVMName -eq 'OTHER-PRI')
    Assert-RoleTest ($plans.Count -eq 2) 'Mixed sites were not isolated into two owner actions.'
    Assert-RoleTest (($first[0].TargetVMNames -join ',') -eq 'CHILD-DP,EDITED-DP') 'Secondary ownership/explicit existing target routing is wrong.'
    Assert-RoleTest (($second[0].TargetVMNames -join ',') -eq 'OTHER-DP') 'Second owner received targets from another site.'
    $script:Cases++

    $config = New-RoleTestConfig
    $config.virtualMachines += New-RoleTestVM -Name STANDALONE -Role WSUS -Properties @{ siteCode = '' }
    Assert-RoleTest (@(Get-MemLabsExistingRoleActions -DeployConfig $config).Count -eq 0) 'Context-only roles or standalone WSUS scheduled Primary changes.'
    $config = New-RoleTestConfig -Targets @((New-RoleTestVM -Properties @{ installDP = $true }))
    $config.virtualMachines[0].hidden = $false
    Assert-RoleTest (@(Get-MemLabsExistingRoleActions -DeployConfig $config).Count -eq 0) 'A new Primary was incorrectly scheduled as an existing-Primary actor.'
    $script:Cases++

    foreach ($bad in @(
            @{ VM = (New-RoleTestVM -Properties @{ siteCode = '' }); Pattern = '*explicit three-character site code*' },
            @{ VM = (New-RoleTestVM -Properties @{ siteCode = 'BAD' }); Pattern = '*Cannot resolve one Primary owner*' },
            @{ VM = (New-RoleTestVM -Properties @{ enablePullDP = $true }); Pattern = '*must also request installDP*' }
        )) {
        $config = New-RoleTestConfig -Targets @($bad.VM)
        Assert-RoleThrows { Get-MemLabsExistingRoleActions -DeployConfig $config } $bad.Pattern
        $script:Cases++
    }
    $config = New-RoleTestConfig -Targets @((New-RoleTestVM), (New-RoleTestVM))
    Assert-RoleThrows { Get-MemLabsExistingRoleActions -DeployConfig $config } '*uniquely resolve requested site-role VM*'
    $script:Cases++
    $config = New-RoleTestConfig
    $sql = @($config.virtualMachines | Where-Object vmName -eq 'OLD-SQL')[0]
    $sql.siteCode = ''
    $sql | Add-Member NoteProperty ExistingVM $true
    $plan = @(Get-MemLabsExistingRoleActions $config)
    Assert-RoleTest ($plan.Count -eq 1 -and $plan[0].TargetVMNames[0] -eq 'OLD-SQL') 'An explicitly edited remote SQL Reporting Point lost its unique Primary owner.'
    Assert-RoleTest ($sql.siteCode -eq '') 'Remote SQL ownership resolution rewrote the original SQL VM configuration.'
    $script:Cases++
}

if ($Mode -in @('All', 'Handler')) {
    $functionsPath = Join-Path $RootPath 'DSC\phases\ScriptFunctions.ps1'
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($functionsPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw "Cannot import shipped SQL target helper: $($parseErrors -join '; ')" }
    foreach ($functionName in @('Get-VmSqlConnectionTarget', 'Test-SecondarySiteReplicationActive')) {
        $definition = @($ast.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
                }, $true))
        if ($definition.Count -ne 1) { throw "Expected one shipped $functionName definition." }
        . ([scriptblock]::Create($definition[0].Extent.Text))
    }

    function Get-TestKey { param([string]$Code, [string]$Fqdn) return "$Code|$Fqdn".ToLowerInvariant() }
    function Get-TestComputerSid {
        param([string]$Name)
        $names = @($script:Config.virtualMachines | Where-Object { $_ } | ForEach-Object vmName)
        $index = [Array]::IndexOf($names, $Name)
        if ($index -lt 0) { throw "Unmocked computer '$Name'." }
        return [Security.Principal.SecurityIdentifier]::new("S-1-5-21-101-102-103-$($index + 1000)")
    }
    function Register-TestComputerGrant {
        param([string]$Kind, [string]$Endpoint, [string]$Account)
        $authorized = @(($script:Action.Payload | ConvertFrom-Json).Targets | Where-Object {
                $_.IsNewTarget -and $_.role -eq 'PassiveSite' -and "LAB\$($_.vmName)`$" -eq $Account
            })
        Assert-RoleTest ($authorized.Count -eq 1) "Grant changed a principal other than the exact new passive computer: $Account."
        Assert-RoleTest ($Endpoint -in @('OLD-PRI.lab.test', 'OLD-SQL.lab.test', 'OLD-SQL2.lab.test', 'OLD-LIB.lab.test')) "Grant escaped required existing endpoints: $Endpoint."
        $script:PrincipalGrants.Add([pscustomobject]@{ Kind = $Kind; Endpoint = $Endpoint; Account = $Account })
    }
    function Register-TestMutation {
        param([string]$Command, [string]$Fqdn, [string]$Code, $Arguments)
        $short = ($Fqdn -split '\.')[0]
        Assert-RoleTest ($script:Action.TargetVMNames -icontains $short) "$Command attempted an unrelated mutation on '$Fqdn'."
        $script:Mutations.Add([pscustomobject]@{ Command = $Command; Fqdn = $Fqdn; SiteCode = $Code; Arguments = $Arguments })
    }
    function Reset-RoleTestState {
        param($Config, $Action, [hashtable]$Faults = @{})
        $script:Config = $Config
        $script:Action = $Action
        $script:Faults = $Faults
        $script:Mutations = [Collections.Generic.List[object]]::new()
        $script:Probes = [Collections.Generic.List[string]]::new()
        $script:SqlQueries = [Collections.Generic.List[object]]::new()
        $script:SqlConnectionTargets = [Collections.Generic.List[string]]::new()
        $script:Messages = [Collections.Generic.List[string]]::new()
        $script:Systems = @{}
        $script:NativeRoles = @{ DP = @{}; MP = @{}; SUP = @{}; RP = @{} }
        $script:Sites = @{}
        $script:Providers = @()
        $script:ProviderSiteQueries = [Collections.Generic.List[string]]::new()
        $script:NativeMaintenanceCalls = [Collections.Generic.List[string]]::new()
        $script:PrincipalGrants = [Collections.Generic.List[object]]::new()
        $script:SqlProvisioned = @{}
        $script:GrantedAdmins = @{}
        $script:ShareGranted = $false
        $script:NtfsGranted = $false
        $script:PassiveNodes = @()
        $script:CurrentRemote = ''
        $script:Clock = [datetime]'2026-11-23T12:00:00Z'
        $script:PrereqCalls = 0
        $script:AdkPaths = 0
        $script:RoleReads = @{}
        $script:SecondaryPolls = 0
        $script:PassivePolls = 0
        $script:PassiveSubmitted = $false
        $script:SourceReadPaths = @()
        $script:LibraryCalls = [Collections.Generic.List[object]]::new()
        $script:LibraryChanges = [Collections.Generic.List[object]]::new()
        $script:LibraryNeedsMove = $false
        $script:LibraryMoveActive = $false
        $script:LibraryMovePolls = 0
        $script:LibraryDestination = "\\OLD-LIB\$($Action.SiteCode)\ContentLib"
        $script:LibrarySource = 'E:\SCCMContentLib'
        $script:LibraryPointer = $script:LibraryDestination
        $script:LibraryDrives = $script:LibraryDestination
        $script:LibraryResult = 0
        $script:LibraryShareExists = $true
        $script:LibraryFolderExists = $true
        $script:LibraryRootExists = $true
        $script:LibraryMarkerExists = $false
        $script:LibraryMarkerJson = ''
        $script:LibraryPreparing = $false
        $script:LibraryAcl = $null
        $script:LibraryShareAccounts = @()
        foreach ($siteVM in @($Config.virtualMachines | Where-Object { $_ -and $_.role -in @('Primary', 'Secondary') -and $_.hidden })) {
            $type = 2
            if ($siteVM.role -eq 'Secondary') { $type = 1 }
            $script:Sites[$siteVM.siteCode] = [pscustomobject]@{
                SiteCode = $siteVM.siteCode; Type = $type; Status = 1; ServerName = "$($siteVM.vmName).lab.test"
                ReportingSiteCode = "$($siteVM.parentSiteCode)"; ContentLibraryLocation = "\\OLD-LIB\$($siteVM.siteCode)\ContentLib"
            }
        }
        $script:NativeRoles.MP[(Get-TestKey $Action.SiteCode "$($Action.OwnerVMName).lab.test")] =
            [pscustomobject]@{ SiteCode = $Action.SiteCode; NetworkOSPath = "\\$($Action.OwnerVMName).lab.test" }
        $script:Systems[(Get-TestKey $Action.SiteCode "$($Action.OwnerVMName).lab.test")] =
            [pscustomobject]@{ SiteCode = $Action.SiteCode; NetworkOSPath = "\\$($Action.OwnerVMName).lab.test" }
    }
    function Invoke-RoleTestHandler {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'deployConfig', Justification = 'Consumed by the shipped guest handler.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'ThisVM', Justification = 'Consumed by the shipped guest handler.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'SiteCode', Justification = 'Consumed by the shipped guest handler.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'DomainFullName', Justification = 'Consumed by the shipped guest handler.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'NetbiosDomainName', Justification = 'Consumed by the shipped guest handler.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'Admincreds', Justification = 'Consumed by the shipped guest handler.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'LogPath', Justification = 'Consumed by the shipped guest handler.')]
        [CmdletBinding()]
        param($Config, $Action)
        $deployConfig = $Config
        $ThisVM = @($Config.virtualMachines | Where-Object vmName -eq $Action.OwnerVMName)[0]
        $SiteCode = $Action.SiteCode
        $DomainFullName = $Config.vmOptions.domainName
        $NetbiosDomainName = $Config.vmOptions.domainNetBiosName
        $password = [Security.SecureString]::new()
        $password.AppendChar([char]120)
        $Admincreds = [Management.Automation.PSCredential]::new('LAB\LabAdmin', $password)
        $LogPath = Join-Path $RootPath 'owned-role-test-state-not-created'
        $oldComputerName = $env:COMPUTERNAME
        try {
            $env:COMPUTERNAME = $Action.OwnerVMName
            $shipped = [scriptblock]::Create($Action.Handler.ToString())
            $output = @(& $shipped $Action.Payload)
            Assert-RoleTest ($output.Count -eq 1) 'Handler leaked success-stream output instead of exactly one receipt.'
            Assert-RoleTest (($output[0].TargetVMNames -join ',') -ceq ($Action.TargetVMNames -join ',')) 'Handler receipt did not preserve the exact planned target set/order.'
            Assert-RoleTest ($script:NativeMaintenanceCalls.Count -eq 0) 'Handler attempted setup/service/native site maintenance.'
            return $output[0]
        }
        finally { $env:COMPUTERNAME = $oldComputerName }
    }
    function Initialize-TestLibraryMove {
        $script:LibraryNeedsMove = $true
        $script:LibraryPointer = $script:LibrarySource
        $script:LibraryDrives = $script:LibrarySource
        $script:LibraryResult = 131077
        $script:Sites[$script:Action.SiteCode].ContentLibraryLocation = $script:LibrarySource
        $target = @($script:Config.virtualMachines | Where-Object { $_ -and $_.role -eq 'PassiveSite' })[0]
        Initialize-MemLabsScopedHierarchyActionRun -DeployConfig $script:Config -Actions @($script:Action) `
            -RunId ([guid]'11111111-2222-3333-4444-555555555555')
        Assert-RoleTest ($target.phase8ScopedHierarchyAction.Kind -eq 'SiteRoles') 'Actual parent initializer did not provide the reservation contract.'
        foreach ($site in $script:Sites.Values) {
            $site | Add-Member -MemberType ScriptProperty -Name ContentLibraryStatus -Value { throw 'Unsafe global TOP1 ContentLibraryStatus was read.' } -Force
            $site | Add-Member -MemberType ScriptProperty -Name ContentLibraryMoveProgress -Value { throw 'Unsafe global TOP1 ContentLibraryMoveProgress was read.' } -Force
        }
    }
    function Get-Date { param() return $script:Clock }
    function Start-Sleep { param([int]$Seconds) $script:Clock = $script:Clock.AddSeconds([Math]::Max(15, $Seconds)) }
    function Join-Path { param([string]$Path, [string]$ChildPath) return [IO.Path]::Combine($Path, $ChildPath) }
    function Get-Location { [pscustomobject]@{ Drive = [pscustomobject]@{ Name = $script:Action.SiteCode } } }
    function Write-DscStatus {
        param([string]$Message, [int]$RetrySeconds, [switch]$Failure)
        if ($Failure) { throw "Unexpected Write-DscStatus -Failure: $Message" }
        $script:Messages.Add($Message)
    }
    function Get-CMSite {
        [CmdletBinding()]param([string]$SiteCode)
        if (-not $SiteCode) { throw 'Unscoped Get-CMSite is forbidden by this fixture.' }
        if ($script:Faults.OwnerRead -and $SiteCode -eq $script:Action.SiteCode) { throw 'synthetic owner provider/SQL read failure' }
        if ($script:Sites.ContainsKey($SiteCode) -and $script:Sites[$SiteCode].Type -eq 1 -and $script:Sites[$SiteCode].Status -eq 2) {
            $script:SecondaryPolls++
            if (-not $script:Faults.PendingSecondary -and $script:SecondaryPolls -ge 2) { $script:Sites[$SiteCode].Status = 1 }
        }
        return $script:Sites[$SiteCode]
    }
    function Get-Service {
        [CmdletBinding()]param([string]$Name)
        $status = 'Running'
        if ($script:Faults.OwnerService -and -not $script:CurrentRemote) { $status = 'Stopped' }
        if ($script:Faults.DependencyService -and $script:CurrentRemote -like "$($script:Faults.DependencyService).*") { $status = 'Stopped' }
        [pscustomobject]@{ Name = $Name; Status = $status }
    }
    function New-Object {
        [CmdletBinding()]param([string]$TypeName, [object[]]$ArgumentList)
        if ($TypeName -ne 'System.Data.SqlClient.SqlConnection') { throw "Unmocked New-Object '$TypeName'." }
        $script:SqlConnectionTargets.Add("$($ArgumentList[0])")
        $connection = [pscustomobject]@{ ConnectionString = "$($ArgumentList[0])" }
        $connection | Add-Member ScriptMethod Open { if ($script:Faults.SqlConnect) { throw 'synthetic SQL login failure' } }
        $connection | Add-Member ScriptMethod Dispose {}
        $connection | Add-Member ScriptMethod CreateCommand {
            $parameters = [pscustomobject]@{ Values = @{} }
            $parameters | Add-Member ScriptMethod AddWithValue { param($Name, $Value) $this.Values[$Name] = $Value }
            $command = [pscustomobject]@{ CommandText = ''; CommandTimeout = 0; Parameters = $parameters; DataSource = $this.ConnectionString }
            $command | Add-Member ScriptMethod Dispose {}
            $command | Add-Member ScriptMethod ExecuteScalar {
                Assert-RoleTest ($this.CommandText -match '^SELECT ') 'Actor attempted a SQL mutation.'
                $script:SqlQueries.Add([pscustomobject]@{
                        Text = $this.CommandText; Parameters = $this.Parameters.Values; DataSource = $this.DataSource
                    })
                if ($this.CommandText -match 'state_desc') {
                    if ($script:Faults.SqlOffline) { return 'OFFLINE' }
                    if ($script:Faults.SecondarySqlOffline -and $this.Parameters.Values['@database'] -eq 'CM_SEC') { return 'OFFLINE' }
                    return 'ONLINE'
                }
                if ($this.CommandText -match 'IS_SRVROLEMEMBER') {
                    if ($script:Faults.SqlSysadmin) { return 0 }
                    $login = "$($this.Parameters.Values['@login'])"
                    if ($script:Faults.NewBindingsMissing -and $login -eq 'LAB\NEW-ROLE$' -and -not $script:SqlProvisioned["$($this.DataSource)|$login"]) { return 0 }
                    return 1
                }
                if ($this.CommandText -match 'sys.server_principals.*FOR JSON PATH') {
                    $login = "$($this.Parameters.Values['@login'])"
                    if ($script:Faults.NewBindingsMissing -and -not $script:Faults.NewLoginExists -and
                        $login -eq 'LAB\NEW-ROLE$' -and -not $script:SqlProvisioned["$($this.DataSource)|$login"]) { return '[]' }
                    $name = $login.Split('\')[-1].TrimEnd('$')
                    $sid = Get-TestComputerSid $name
                    $bytes = [byte[]]::new($sid.BinaryLength)
                    $sid.GetBinaryForm($bytes, 0)
                    $hex = '0x' + ([BitConverter]::ToString($bytes) -replace '-', '')
                    if ($script:Faults.SqlSidConflict -eq $name) { $hex = '0x00' }
                    return ([pscustomobject]@{ name = $login; type = 'U'; is_disabled = 0; SidHex = $hex } | ConvertTo-Json -Compress)
                }
                throw "Unmocked SQL query '$($this.CommandText)'."
            }
            $command | Add-Member ScriptMethod ExecuteNonQuery {
                $login = "$($this.Parameters.Values['@login'])"
                Assert-RoleTest ($this.CommandText -match 'CREATE LOGIN' -and $this.CommandText -match 'ALTER SERVER ROLE \[sysadmin\] ADD MEMBER') 'Unexpected SQL provisioning operation.'
                $match = [regex]::Match($this.DataSource, 'Data Source=([^;]+)')
                $endpoint = ($match.Groups[1].Value -split '[\\,]')[0]
                Register-TestComputerGrant Sql $endpoint $login
                $script:SqlProvisioned["$($this.DataSource)|$login"] = $true
                return 1
            }
            return $command
        }
        return $connection
    }
    function Get-CMSiteSystemServer {
        [CmdletBinding()]param([string]$SiteSystemServerName, [string]$SiteCode)
        if (-not $SiteCode) { throw 'Unscoped site-system enumeration.' }
        if ($SiteSystemServerName) { return $script:Systems[(Get-TestKey $SiteCode $SiteSystemServerName)] }
        return @($script:Systems.Values | Where-Object SiteCode -eq $SiteCode)
    }
    function New-CMSiteSystemServer {
        [CmdletBinding()]param([string]$SiteSystemServerName, [string]$SiteCode)
        Register-TestMutation 'New-CMSiteSystemServer' $SiteSystemServerName $SiteCode $PSBoundParameters
        $value = [pscustomobject]@{ SiteCode = $SiteCode; NetworkOSPath = "\\$SiteSystemServerName" }
        $script:Systems[(Get-TestKey $SiteCode $SiteSystemServerName)] = $value
        return $value
    }
    function Get-TestNativeRole {
        param([string]$Role, [string]$Fqdn, [string]$Code)
        if ($Fqdn) { return $script:NativeRoles[$Role][(Get-TestKey $Code $Fqdn)] }
        if ($Role -eq 'MP' -and $script:Faults.ParentMp) { return }
        return @($script:NativeRoles[$Role].Values | Where-Object SiteCode -eq $Code)
    }
    function Get-CMDistributionPoint { [CmdletBinding()]param($SiteSystemServerName, $SiteCode) Get-TestNativeRole DP $SiteSystemServerName $SiteCode }
    function Get-CMManagementPoint { [CmdletBinding()]param($SiteSystemServerName, $SiteCode) Get-TestNativeRole MP $SiteSystemServerName $SiteCode }
    function Get-CMSoftwareUpdatePoint { [CmdletBinding()]param($SiteSystemServerName, $SiteCode) Get-TestNativeRole SUP $SiteSystemServerName $SiteCode }
    function Get-CMReportingServicePoint {
        [CmdletBinding()]param($SiteSystemServerName)
        return @($script:NativeRoles.RP.Values | Where-Object { $_.NetworkOSPath -eq "\\$SiteSystemServerName" })
    }
    function Add-TestNativeRole {
        param([string]$Role, [string]$Fqdn, [string]$Code, $Arguments)
        Register-TestMutation "Add-$Role" $Fqdn $Code $Arguments
        if ($script:Faults.AddRole -eq $Role) { Write-Error "synthetic $Role submission failure"; return }
        $script:NativeRoles[$Role][(Get-TestKey $Code $Fqdn)] =
            [pscustomobject]@{ SiteCode = $Code; NetworkOSPath = "\\$Fqdn" }
    }
    function Add-CMDistributionPoint {
        [CmdletBinding()]param(
            $SiteSystemServerName, $SiteCode, $CertificateExpirationTimeUtc, $CertificatePath, [Security.SecureString]$CertificatePassword,
            [switch]$EnablePxe, [switch]$EnableNonWdsPxe, [switch]$AllowPxeResponse, [switch]$EnableUnknownComputerSupport,
            [switch]$EnableSSL, [switch]$Force, [switch]$EnablePullDP, $SourceDistributionPoint
        )
        Add-TestNativeRole DP $SiteSystemServerName $SiteCode $PSBoundParameters
    }
    function Add-CMManagementPoint {
        [CmdletBinding()]param($InputObject, $CommunicationType, [switch]$EnableSSL)
        Add-TestNativeRole MP "$($InputObject.NetworkOSPath)".TrimStart('\') $InputObject.SiteCode $PSBoundParameters
    }
    function Add-CMSoftwareUpdatePoint {
        [CmdletBinding()]param($SiteSystemServerName, $SiteCode, $WsusIisPort, $WsusIisSslPort, [bool]$WsusSSL)
        Add-TestNativeRole SUP $SiteSystemServerName $SiteCode $PSBoundParameters
    }
    function Add-CMReportingServicePoint {
        [CmdletBinding()]param($SiteSystemServerName, $SiteCode, $UserName, $DatabaseServerName, $DatabaseName, $ReportServerInstance)
        Add-TestNativeRole RP $SiteSystemServerName $SiteCode $PSBoundParameters
    }
    function Get-TestRoleReadiness {
        param([string]$Role, [string]$Fqdn, [string]$Code)
        $script:Probes.Add("$Role|$Code|$Fqdn")
        $visible = [bool]$script:NativeRoles[$Role][(Get-TestKey $Code $Fqdn)]
        $ready = $visible -and $Fqdn -notlike 'OLD-BROKEN.*'
        $key = "$Role|$Code|$Fqdn"
        $script:RoleReads[$key] = [int]$script:RoleReads[$key] + 1
        if ($script:Faults.RoleNotReady -eq $Role -or $script:Faults.PendingForever -eq $Role -or
            ($script:Faults.PendingRole -eq $Role -and $script:RoleReads[$key] -lt 3)) { $ready = $false }
        if ($script:Faults.SourceDp -and $Fqdn -like 'SOURCE.*') { $ready = $false }
        if ($Role -eq 'SUP' -and $script:Faults.SelectedUpstreamBroken -and $Fqdn -eq 'CAS-SUP.lab.test') { $ready = $false }
        [pscustomobject]@{ Ready = $ready; ConfigurationVisible = $visible; Detail = "synthetic $Role physical ready=$ready on $Fqdn" }
    }
    function Get-CMDistributionPointReadiness {
        param($ServerFQDN, $SiteCode)
        Assert-RoleTest ($script:Action.TargetVMNames -icontains ($ServerFQDN -split '\.')[0]) 'Write-capable shared DP readiness was used on a retained source.'
        Get-TestRoleReadiness DP $ServerFQDN $SiteCode
    }
    function Get-CMManagementPointReadiness { param($ServerFQDN, $SiteCode) Get-TestRoleReadiness MP $ServerFQDN $SiteCode }
    function Get-CMSoftwareUpdatePointReadiness { param($ServerFQDN, $SiteCode) Get-TestRoleReadiness SUP $ServerFQDN $SiteCode }
    function Get-CMReportingPointReadiness { param($ServerFQDN, $SiteCode) Get-TestRoleReadiness RP $ServerFQDN $SiteCode }
    function Get-CMRoleTargetPrerequisiteState {
        param($ServerFQDN, $RoleName)
        Assert-RoleTest ($script:Action.TargetVMNames -icontains ($ServerFQDN -split '\.')[0]) 'Mutation-capable prerequisite helper was used against a retained dependency.'
        $script:PrereqCalls++
        if ($script:Faults.TargetFeature) {
            return [pscustomobject]@{
                Ready = $false; MissingFeatures = @('Rdc'); GuestProbeReady = $true; IdentityReady = $true
                SiteServerAdmin = $true; Detail = 'Phase 3 Rdc feature prerequisite missing'
            }
        }
        $ready = -not $script:Faults.TargetPrereq
        if ($script:Faults.DelayedTarget -and $script:PrereqCalls -eq 1) { $ready = $false }
        [pscustomobject]@{ Ready = $ready; Detail = 'synthetic target prerequisites (not an old workflow receipt)' }
    }
    function Test-MPHttpsBinding { param($MPFQDN) return -not [bool]$script:Faults.Https }
    function Get-CMAccount {
        [CmdletBinding()]param($SiteCode, $UserName)
        if (-not $script:Faults.ReportingAccount) { [pscustomobject]@{ SiteCode = $SiteCode; UserName = $UserName } }
    }
    function Invoke-CMRoleTargetCommand {
        param($ComputerName, [scriptblock]$ScriptBlock, [object[]]$ArgumentList)
        $script:Probes.Add("Remote|$ComputerName")
        $old = $script:CurrentRemote
        $script:CurrentRemote = $ComputerName
        try {
            if ($script:Faults.Remote -and $ComputerName -like "$($script:Faults.Remote).*") { throw "synthetic retained '$ComputerName' unreachable" }
            if ($ScriptBlock.ToString().Contains('[Microsoft.Win32.RegistryView]::Registry64')) {
                if ($script:Faults.LibraryRegistryKind) { throw 'Required native ContentLibUsableDrives is not REG_SZ.' }
                return [pscustomobject]@{ Path = $script:LibraryPointer; Drives = $script:LibraryDrives }
            }
            if ($ScriptBlock.ToString().Contains('GetUpdateServerConfigurationState')) {
                $script:Probes.Add("SelectedSUP|$($ArgumentList[0])")
                return [pscustomobject]@{ State = $(if ($script:Faults.RoleNotReady -eq 'SUP' -or $script:Faults.SelectedUpstreamBroken) { 'Busy' } else { 'Ready' }) }
            }
            & $ScriptBlock @ArgumentList
        }
        finally { $script:CurrentRemote = $old }
    }
    function Get-LocalGroupMember {
        [CmdletBinding()]param($SID)
        $endpoint = @($script:Config.virtualMachines | Where-Object { $_.vmName -eq ($script:CurrentRemote -split '\.')[0] })[0]
        $siteVMs = @($script:Config.virtualMachines | Where-Object { $_ -and $_.role -in @('Primary', 'Secondary', 'PassiveSite') })
        $accountLists = [pscustomobject]@{ LocalAdminAccounts = @() }
        Add-VMToAccountLists -thisVM $endpoint -VM $siteVMs -accountLists $accountLists -deployConfig $script:Config -LocalAdminAccounts
        foreach ($vm in @($siteVMs | Where-Object { "$($_.vmName)`$" -in $accountLists.LocalAdminAccounts })) {
            if ($script:Faults.Admin -and $script:CurrentRemote -like "$($script:Faults.Admin).*" -and $vm.vmName -eq 'OLD-PRI') { continue }
            $sidValue = Get-TestComputerSid $vm.vmName
            if ($script:Faults.NewBindingsMissing -and $vm.role -eq 'PassiveSite' -and
                -not $script:GrantedAdmins["$script:CurrentRemote|$sidValue"]) { continue }
            [pscustomobject]@{ Name = "LAB\$($vm.vmName)`$"; SID = $sidValue }
        }
    }
    function Get-ADComputer {
        [CmdletBinding()]param($Identity, $Server, $Properties)
        Assert-RoleTest ($Server -eq 'lab.test') 'Computer identity lookup escaped the owning domain.'
        [pscustomobject]@{ Enabled = $true; SamAccountName = "$Identity`$"; SID = (Get-TestComputerSid $Identity) }
    }
    function Test-ComputerSecureChannel {
        [CmdletBinding()]param()
        return -not ($script:Faults.Trust -and $script:CurrentRemote -like "$($script:Faults.Trust).*")
    }
    function Add-LocalGroupMember {
        [CmdletBinding()]param($SID, $Member)
        $target = @(($script:Action.Payload | ConvertFrom-Json).Targets | Where-Object { "$(Get-TestComputerSid $_.vmName)" -eq "$Member" })
        if ($SID -ne 'S-1-5-32-544' -or $target.Count -ne 1) { throw 'Unexpected administrator provisioning.' }
        Register-TestComputerGrant Admin $script:CurrentRemote "LAB\$($target[0].vmName)`$"
        $script:GrantedAdmins["$script:CurrentRemote|$Member"] = $true
    }
    function New-CMInstallationSourceFile { [CmdletBinding()]param([switch]$CopyFromParentSiteServer) [pscustomobject]@{ CopyFromParent = $true } }
    function New-CMSqlServerSetting {
        [CmdletBinding()]param(
            $SiteDatabaseName, [switch]$UseExistingSqlServerInstance, $InstanceName, $SqlServerServiceBrokerPort,
            [switch]$CopySqlServerExpressOnSecondarySite, $SqlServerServicePort
        )
        return [pscustomobject]$PSBoundParameters
    }
    function New-CMSecondarySite {
        [CmdletBinding()]param(
            $PrimarySiteCode, $SecondarySiteCode, $ServerName, $InstallationFolder, $InstallationSourceFile,
            [bool]$InstallInternetServer, $SiteName, $SqlServerSetting, [switch]$Https, [switch]$Http,
            [switch]$ImportCertificate, $CertificatePath, [Security.SecureString]$CertificatePassword, [switch]$ForceWhenDuplicateCertificate,
            [switch]$CreateSelfSignedCertificate, $CertificateExpirationTimeUtc
        )
        Register-TestMutation 'New-CMSecondarySite' $ServerName $PrimarySiteCode $PSBoundParameters
        if ($script:Faults.SecondarySubmit) { Write-Error 'synthetic secondary submission failure'; return }
        $status = 2
        if ($script:Faults.SecondaryActive) { $status = 1 }
        $script:Sites[$SecondarySiteCode] = [pscustomobject]@{
            SiteCode = $SecondarySiteCode; Type = 1; Status = $status
            ServerName = $ServerName; ReportingSiteCode = $PrimarySiteCode
        }
        foreach ($role in @('DP', 'MP')) {
            $script:NativeRoles[$role][(Get-TestKey $SecondarySiteCode $ServerName)] =
                [pscustomobject]@{ SiteCode = $SecondarySiteCode; NetworkOSPath = "\\$ServerName" }
        }
    }
    function Get-WmiObject {
        [CmdletBinding()]param($Namespace, $Class, $Filter, $ComputerName)
        if ($Class -eq 'SMS_ProviderLocation') {
            $site = @($script:Sites.Values | Where-Object { $_.ServerName -eq $ComputerName })[0]
            return [pscustomobject]@{ SiteCode = $site.SiteCode; ProviderForLocalSite = $true; Machine = $ComputerName }
        }
        if ($Class -eq 'SMS_SCI_Component') {
            return [pscustomobject]@{ ItemName = 'SMS_WSUS_CONFIGURATION_MANAGER|SMS Site Server'; Props = @(
                    [pscustomobject]@{ PropertyName = 'DefaultWSUS'; Value2 = 'CAS-SUP.lab.test' }
                ) }
        }
        if ($Class -eq 'SMS_SCI_SysResUse' -and $Filter -like "*RoleName='SMS Software Update Point'*") {
            [pscustomobject]@{ NetworkOSPath = '\\CAS-SUP.lab.test'; Props = @(
                    [pscustomobject]@{ PropertyName = 'Enabled'; Value = 1 },
                    [pscustomobject]@{ PropertyName = 'SSLWSUS'; Value = 0 },
                    [pscustomobject]@{ PropertyName = 'WSUSIISPort'; Value = 8530 },
                    [pscustomobject]@{ PropertyName = 'NLBVIP'; Value2 = '' }
                ) }
            if ($script:Faults.UnrelatedSup) { [pscustomobject]@{ NetworkOSPath = '\\ALTERNATE.lab.test'; Props = @() } }
            return
        }
        if ($Class -eq 'SMS_DistributionPointInfo') {
            if ($Namespace -notmatch 'site_([a-zA-Z0-9]{3})$') { throw 'Unscoped source-DP provider query.' }
            return @($script:NativeRoles.DP.Values | Where-Object SiteCode -eq $Matches[1])
        }
        if ($Class -ne 'SMS_SCI_SysResUse' -or $Filter -notlike "*SiteCode = '$($script:Action.SiteCode)'*") { throw 'Unscoped passive provider query.' }
        if ($script:PassiveSubmitted) {
            $script:PassivePolls++
            if ($script:Faults.PassiveFailed) { $script:PassiveNodes[0].ServerState = 131071 }
            elseif (-not $script:Faults.PendingPassive -and $script:PassivePolls -ge 3) { $script:PassiveNodes[0].ServerState = 196611 }
        }
        return $script:PassiveNodes
    }
    function Get-CMDatabaseReplicationStatus {
        [CmdletBinding()]param($Site1, $Site2)
        Assert-RoleTest ($Site1 -eq $script:Action.SiteCode -and $Site2 -eq 'SEC') 'DRS readiness query escaped the requested secondary link.'
        if ($script:Faults.DrsRead) { throw 'synthetic DRS provider failure' }
        if ($script:Faults.DrsMissing) { return }
        $state = 2
        if ($script:Faults.DrsFailed) { $state = 9 }
        if ($script:Faults.DrsPending) { $state = 4 }
        [pscustomobject]@{ LinkStatus = $state; Site1ToSite2GlobalState = $state; Site2ToSite1GlobalState = $state }
    }
    function Add-CMPassiveSite {
        [CmdletBinding()]param($InstallDirectory, $SiteCode, $SiteSystemServerName, $SourceFilePathOption)
        Register-TestMutation 'Add-CMPassiveSite' $SiteSystemServerName $SiteCode $PSBoundParameters
        $script:PassiveNodes = @([pscustomobject]@{ SiteCode = $SiteCode; NetworkOSPath = "\\$SiteSystemServerName"; ServerState = 65537 })
        $script:PassiveSubmitted = $true
    }
    function Get-Item {
        [CmdletBinding()]param($LiteralPath, [switch]$Force)
        if ($LiteralPath -like 'FileSystem::\\SOURCE.lab.test\SMS_DP$') {
            $script:SourceReadPaths += $LiteralPath
            if ($script:Faults.SourceRead) { throw 'synthetic retained source access denied' }
        }
        elseif ($LiteralPath -notlike 'E:\*' -and $LiteralPath -notlike 'FileSystem::E:\*') { throw "Unexpected filesystem path '$LiteralPath'." }
        if ($script:Faults.LibrarySourceBroken -and $LiteralPath -like '*SCCMContentLib*') { throw 'Required existing library source is unreadable' }
        [pscustomobject]@{ FullName = $LiteralPath; PSIsContainer = $true; Attributes = [IO.FileAttributes]::Directory }
    }
    function Get-ChildItem {
        [CmdletBinding()]param($LiteralPath, [switch]$Force)
        if ($LiteralPath -like '*SMS_DP$') { return Get-Item -LiteralPath $LiteralPath -Force:$Force }
        if ($LiteralPath -eq 'E:\PRI\ContentLib') {
            if ($script:Faults.LibraryPopulated -or -not $script:LibraryNeedsMove -or $script:LibraryMoveActive) {
                [pscustomobject]@{ Name = 'FileLib'; PSIsContainer = $true }
            }
            return
        }
        if ($LiteralPath -like '*SCCMContentLib*') { return Get-Item -LiteralPath $LiteralPath -Force:$Force }
    }
    function Start-Job {
        param([scriptblock]$ScriptBlock, [object[]]$ArgumentList)
        [pscustomobject]@{ State = 'Completed'; Output = @(& $ScriptBlock @ArgumentList) }
    }
    function Wait-Job { param($Job, [int]$Timeout) return $Job }
    function Receive-Job { [CmdletBinding()]param($Job) return $Job.Output }
    function Stop-Job { [CmdletBinding()]param($Job) $Job.State = 'Stopped' }
    function Remove-Job { [CmdletBinding()]param($Job) }
    function Get-SmbShare {
        [CmdletBinding()]param($Name)
        if ($Name -eq 'ALIAS' -and $script:Faults.LibraryShareAlias) { return [pscustomobject]@{ Name = $Name; Path = 'E:\PRI' } }
        if ($Name -eq $script:Action.SiteCode -and -not $script:LibraryShareExists) {
            $record = [Management.Automation.ErrorRecord]::new(
                [Management.Automation.ItemNotFoundException]::new('Reserved site share is absent'),
                'ShareNotFound', [Management.Automation.ErrorCategory]::ObjectNotFound, $Name)
            $PSCmdlet.ThrowTerminatingError($record)
        }
        [pscustomobject]@{ Name = $Name; Path = "E:\$Name" }
    }
    function Get-SmbShareAccess {
        [CmdletBinding()]param($Name)
        if ($script:LibraryNeedsMove -and $script:Faults.LibraryFreshDestinationAccess) {
            foreach ($account in $script:LibraryShareAccounts) {
                [pscustomobject]@{ AccountName = $account; AccessControlType = 'Allow'; AccessRight = 'Full' }
            }
            return
        }
        foreach ($vm in @($script:Config.virtualMachines | Where-Object { $_ -and $_.role -in @('Primary', 'PassiveSite') })) {
            if ($script:Faults.NewBindingsMissing -and $vm.role -eq 'PassiveSite' -and -not $script:ShareGranted) { continue }
            [pscustomobject]@{ AccountName = "LAB\$($vm.vmName)`$"; AccessControlType = 'Allow'; AccessRight = 'Full' }
        }
    }
    function Grant-SmbShareAccess {
        [CmdletBinding()]param($Name, $AccountName, $AccessRight, [switch]$Force)
        Assert-RoleTest ($Name -eq $script:Action.SiteCode -and $AccessRight -eq 'Full') 'Unexpected share provisioning scope.'
        if ($script:LibraryPreparing -and -not $script:LibraryMoveActive) {
            Assert-RoleTest ($AccountName -in @('LAB\OLD-PRI$', 'LAB\NEW-ROLE$') -and $script:CurrentRemote -eq 'OLD-LIB.lab.test') 'New destination share authorization escaped active/passive principals.'
            $script:LibraryShareAccounts += $AccountName
            $script:LibraryChanges.Add("Share:$AccountName")
            return
        }
        Register-TestComputerGrant Share $script:CurrentRemote $AccountName
        $script:ShareGranted = $true
    }
    function Get-Acl {
        [CmdletBinding()]param($LiteralPath)
        $entries = @($script:Config.virtualMachines | Where-Object { $_ -and $_.role -in @('Primary', 'PassiveSite') } |
                ForEach-Object {
                    if (-not ($script:Faults.NewBindingsMissing -and $_.role -eq 'PassiveSite' -and -not $script:NtfsGranted)) {
                        [pscustomobject]@{
                            IdentityReference = "LAB\$($_.vmName)`$"; AccessControlType = 'Allow'
                            FileSystemRights = [Security.AccessControl.FileSystemRights]::FullControl
                        }
                    }
                })
        if ($script:Faults.LibraryAcl) { $entries = @() }
        if ($script:LibraryNeedsMove -and $script:Faults.LibraryFreshDestinationAccess) { $entries = @() }
        if ($null -ne $script:LibraryAcl) { $entries = @($script:LibraryAcl) }
        if ($script:Faults.LibraryDeny) {
            $entries += [pscustomobject]@{ IdentityReference = 'S-1-1-0'; AccessControlType = 'Deny'; FileSystemRights = [Security.AccessControl.FileSystemRights]::FullControl }
        }
        $value = [pscustomobject]@{ Access = $entries }
        $value | Add-Member ScriptMethod GetAccessRules {
            param($Explicit, $Inherited, $IdentityType)
            foreach ($entry in $this.Access) {
                $identity = "$($entry.IdentityReference)"
                if ($identity -notlike 'S-1-*') { $identity = "$(Get-TestComputerSid ($identity.Split('\')[-1].TrimEnd('$')))" }
                [pscustomobject]@{ IdentityReference = $identity; AccessControlType = $entry.AccessControlType; FileSystemRights = $entry.FileSystemRights }
            }
        }
        $value | Add-Member ScriptMethod AddAccessRule {
            param($Rule)
            $this.Access += [pscustomobject]@{
                IdentityReference = "$($Rule.IdentityReference)"; AccessControlType = "$($Rule.AccessControlType)"
                FileSystemRights = $Rule.FileSystemRights
            }
        }
        return $value
    }
    function Set-Acl {
        [CmdletBinding()]param($LiteralPath, $AclObject)
        if ($script:LibraryPreparing -and -not $script:LibraryMoveActive) {
            $allowed = @("$(Get-TestComputerSid OLD-PRI)", "$(Get-TestComputerSid NEW-ROLE)")
            Assert-RoleTest ($LiteralPath -eq 'E:\PRI\ContentLib' -and
                @($AclObject.Access | Where-Object { "$($_.IdentityReference)" -notin $allowed }).Count -eq 0) 'New destination ACL initialization changed unrelated principals/path.'
            $script:LibraryAcl = @($AclObject.Access)
            $script:LibraryChanges.Add('DestinationNtfs')
            return
        }
        $newEntries = @($AclObject.Access | Where-Object { "$($_.IdentityReference)" -like 'S-1-*' })
        Assert-RoleTest ($newEntries.Count -eq 1) 'NTFS provisioning changed more than one explicit new principal.'
        $target = @(($script:Action.Payload | ConvertFrom-Json).Targets | Where-Object {
                "$(Get-TestComputerSid $_.vmName)" -eq "$($newEntries[0].IdentityReference)"
            })
        Assert-RoleTest ($target.Count -eq 1) 'NTFS provisioning escaped the exact requested principal.'
        $oldExpected = @((Get-Acl -LiteralPath $LiteralPath).Access | ForEach-Object { "$($_.IdentityReference)|$($_.FileSystemRights)|$($_.AccessControlType)" } | Sort-Object)
        $oldActual = @($AclObject.Access | Where-Object { "$($_.IdentityReference)" -notlike 'S-1-*' } |
                ForEach-Object { "$($_.IdentityReference)|$($_.FileSystemRights)|$($_.AccessControlType)" } | Sort-Object)
        Assert-RoleTest (($oldExpected -join ';') -ceq ($oldActual -join ';')) 'New-principal NTFS provisioning altered old ACL entries.'
        Register-TestComputerGrant Ntfs $script:CurrentRemote "LAB\$($target[0].vmName)`$"
        $script:NtfsGranted = $true
    }
    function Get-CimInstance {
        [CmdletBinding()]param($ComputerName, $Namespace, $ClassName, $Filter, $OperationTimeoutSec)
        switch ($ClassName) {
            'Win32_ComputerSystem' {
                $name = $script:CurrentRemote
                if ($ComputerName) { $name = "$ComputerName" }
                [pscustomobject]@{ Name = ($name -split '\.')[0]; Domain = 'lab.test' }
            }
            'SMS_ProviderLocation' {
                if ($script:Faults.ProviderRead) { throw 'synthetic provider read failure' }
                return $script:Providers
            }
            'SMS_Site' {
                if (-not $ComputerName) {
                    if ($script:LibraryMoveActive) {
                        $script:LibraryMovePolls++
                        $site = $script:Sites[$script:Action.SiteCode]
                        if (-not $script:Faults.LibraryWrongSite) { $site.ContentLibraryLocation = $script:LibraryDestination }
                        if (-not $script:Faults.LibraryNeverCutover) {
                            if ($script:LibraryMovePolls -ge 2) { $script:LibraryPointer = $script:LibraryDestination }
                            if ($script:LibraryMovePolls -ge 3) { $script:LibraryDrives = $script:LibraryDestination }
                        }
                        $script:LibraryResult = 131078
                        if ($script:LibraryMovePolls -eq 2 -or $script:LibraryMovePolls -ge 4) { $script:LibraryResult = 0 }
                    }
                    return @($script:Sites.Values)
                }
                Assert-RoleTest ($script:Action.TargetVMNames -icontains ($ComputerName -split '\.')[0]) 'Provider health query escaped the requested exact target.'
                Assert-RoleTest ($Namespace -eq "root\SMS\site_$($script:Action.SiteCode)" -and $Filter -eq "SiteCode='$($script:Action.SiteCode)'") 'Provider health query escaped its owning site.'
                $script:ProviderSiteQueries.Add($ComputerName)
                if ($script:Faults.ProviderNamespace) { throw 'synthetic target provider namespace failure' }
                if ($script:Faults.ProviderSiteMismatch) { return [pscustomobject]@{ SiteCode = 'BAD'; Status = 1 } }
                if ($script:Faults.ProviderInactive) { return [pscustomobject]@{ SiteCode = $script:Action.SiteCode; Status = 2 } }
                return $script:Sites[$script:Action.SiteCode]
            }
            default { throw "Unmocked CIM class '$ClassName'." }
        }
    }
    function Test-Path {
        [CmdletBinding()]param($LiteralPath, $Path, $PathType)
        $value = "$LiteralPath$Path"
        if ($value -like '*MemLabs.ContentLibrary.reservation.json') { return $script:LibraryMarkerExists }
        if ($value -eq 'E:\PRI\ContentLib') { return $script:LibraryFolderExists }
        if ($value -eq 'E:\PRI') { return $script:LibraryRootExists }
        if ($script:Faults.PkiInput -and $value -like '*ConfigMgrClientDistributionPointCertificate.pfx') { return $false }
        if ($script:Faults.DelayedPassiveAdk -and $script:CurrentRemote -like 'NEW-ROLE.*' -and
            $value -like '*Assessment and Deployment Kit*') {
            $script:AdkPaths++
            if ($script:AdkPaths -eq 1) { return $false }
        }
        return $true
    }
    function Get-Content {
        [CmdletBinding()]param($LiteralPath, [switch]$Raw)
        if ($LiteralPath -like '*MemLabs.ContentLibrary.reservation.json' -and $script:LibraryMarkerExists) { return $script:LibraryMarkerJson }
        throw 'Actor unexpectedly read a persisted credential/config file.'
    }
    function New-Item {
        [CmdletBinding()]param($Path, $ItemType, [switch]$Force)
        Assert-RoleTest ($script:LibraryNeedsMove -and $script:CurrentRemote -eq 'OLD-LIB.lab.test' -and
            $Path -in @('E:\PRI\ContentLib', 'E:\PRI\MemLabs.ContentLibrary.reservation.json')) 'Directory/file creation escaped the reserved new destination.'
        if ($ItemType -eq 'Directory') {
            $script:LibraryRootExists = $true
            $script:LibraryFolderExists = $true
            $script:LibraryPreparing = $true
        }
        elseif ($ItemType -eq 'File' -and -not $script:LibraryMarkerExists -and -not $Force) { $script:LibraryMarkerExists = $true }
        else { throw 'Reservation file already exists or attempted overwrite.' }
        $script:LibraryChanges.Add("New:$ItemType")
    }
    function New-SmbShare {
        [CmdletBinding()]param($Name, $Path, [string[]]$FullAccess)
        Assert-RoleTest ($script:LibraryPreparing -and $Name -eq $script:Action.SiteCode -and $Path -eq 'E:\PRI' -and
            ($FullAccess -join ',') -eq 'LAB\OLD-PRI$,LAB\NEW-ROLE$') 'New share creation was not limited to reserved site path/active+passive principals.'
        $script:LibraryShareExists = $true
        $script:LibraryShareAccounts = @($FullAccess)
        $script:LibraryChanges.Add('NewShare')
    }
    function Set-Content {
        [CmdletBinding()]param($LiteralPath, [Parameter(ValueFromPipeline)]$Value, $Encoding)
        process {
            Assert-RoleTest ($script:LibraryPreparing -and $LiteralPath -eq 'E:\PRI\MemLabs.ContentLibrary.reservation.json' -and $script:LibraryMarkerExists) 'State writing escaped the new destination ownership marker.'
            $script:LibraryMarkerJson = "$Value"
            $script:LibraryChanges.Add('Reservation')
        }
    }
    function Invoke-CimMethod {
        [CmdletBinding()]param($Namespace, $ClassName, $MethodName, [hashtable]$Arguments, $OperationTimeoutSec)
        Assert-RoleTest ($Namespace -eq "root\SMS\site_$($script:Action.SiteCode)" -and $ClassName -eq 'SMS_Site' -and
            $Arguments.SiteCode -eq $script:Action.SiteCode) 'Library method escaped the exact owning native site.'
        $script:LibraryCalls.Add([pscustomobject]@{ Method = $MethodName; Arguments = $Arguments })
        if ($MethodName -eq 'RunPrereqCheck') {
            if ($script:Faults.LibraryMissingResult -or ($script:Faults.LibraryMissingResultAfterSubmit -and $script:LibraryMoveActive)) {
                return [pscustomobject]@{ ReturnValue = 0 }
            }
            return [pscustomobject]@{ ReturnValue = 0; Result = $script:LibraryResult }
        }
        if ($MethodName -ne 'SetContentLibraryLocation') { throw 'Unexpected native method; setup/maintenance is forbidden.' }
        Assert-RoleTest ($Arguments.Count -eq 2 -and $Arguments.Location -eq $script:LibraryDestination) 'Native relocation used wrong named arguments/destination.'
        Assert-RoleTest (@($script:LibraryCalls | Where-Object Method -eq 'SetContentLibraryLocation').Count -eq 1) 'Native relocation was resubmitted.'
        if ($script:Faults.LibrarySetFailure) { return [pscustomobject]@{ ReturnValue = 5 } }
        $script:LibraryMoveActive = $true
        $script:LibraryMovePolls = 0
        return [pscustomobject]@{ ReturnValue = 0 }
    }
    # Any path into an old workflow/recovery/global configuration is a test failure.
    foreach ($forbidden in @(
            'Install-DP', 'Install-PullDP', 'Install-MP', 'Install-SUP', 'Install-SRP',
            'Restart-CMRoleProvisioning', 'Repair-CMDistributionPointAccess', 'Confirm-MPHttpsBinding',
            'Start-Service', 'Stop-Service', 'Restart-Service', 'Set-Service',
            'Add-ReportingUser', 'New-CMAccount', 'New-CMAdministrativeUser',
            'Move-CMContentLibrary', 'Remove-CMDistributionPoint', 'Remove-Item', 'Remove-SmbShare',
            'Set-CMSoftwareUpdatePointComponent', 'Sync-CMSoftwareUpdate', 'Test-DrsLinkHealthyViaSql',
            'Start-WsusBaselineImportBackground', 'Invoke-MemLabsDrsGroupSend',
            'Set-ScriptWorkflowStep', 'Write-ScriptWorkflowJsonAtomic', 'Start-DscConfiguration',
            'Read-ScriptWorkflowData', 'Write-ScriptWorkflowData', 'Export-Clixml',
            'Out-File', 'New-ItemProperty', 'Set-ItemProperty',
            'Start-Process', 'Stop-Process', 'Get-Process', 'Get-ItemPropertyValue',
            'Invoke-WmiMethod', 'Set-WmiInstance', 'New-CimInstance', 'Set-CimInstance', 'Remove-CimInstance'
        )) {
        Set-Item -Path "Function:\$forbidden" -Value {
            $script:NativeMaintenanceCalls.Add($MyInvocation.MyCommand.Name)
            throw 'Forbidden existing-hierarchy setup/native maintenance/mutation/recovery helper was called.'
        }
    }

    foreach ($family in @(
            @{ Name = 'bare'; Role = 'SiteSystem'; Properties = @{}; Expected = 'New-CMSiteSystemServer' },
            @{ Name = 'DP'; Role = 'SiteSystem'; Properties = @{ installDP = $true }; Expected = 'Add-DP' },
            @{ Name = 'MP'; Role = 'SiteSystem'; Properties = @{ installMP = $true }; Expected = 'Add-MP' },
            @{ Name = 'SUP'; Role = 'SiteSystem'; Properties = @{ installSUP = $true }; Expected = 'Add-SUP' },
            @{ Name = 'WSUS-SUP'; Role = 'WSUS'; Properties = @{ installSUP = $true }; Expected = 'Add-SUP' },
            @{ Name = 'RP'; Role = 'SiteSystem'; Properties = @{ installRP = $true }; Expected = 'Add-RP' },
            @{ Name = 'provider'; Role = 'SiteSystem'; Properties = @{ hidden = $true; ExistingVM = $true; installSMSProv = $true }; Expected = '' },
            @{ Name = 'secondary'; Role = 'Secondary'; Properties = @{ siteCode = 'SEC'; parentSiteCode = 'PRI'; siteName = 'Explicit secondary' }; Expected = 'New-CMSecondarySite' },
            @{ Name = 'passive'; Role = 'PassiveSite'; Properties = @{ remoteContentLibVM = 'OLD-LIB' }; Expected = 'Add-CMPassiveSite' }
        )) {
        $config = New-RoleTestConfig -Targets @((New-RoleTestVM -Role $family.Role -Properties $family.Properties))
        $action = @(Get-MemLabsExistingRoleActions $config)[0]
        Reset-RoleTestState $config $action
        if ($family.Name -eq 'provider') {
            $script:Providers = @([pscustomobject]@{ Machine = 'NEW-ROLE.lab.test'; SiteCode = 'PRI' })
        }
        $result = Invoke-RoleTestHandler $config $action
        if ($family.Name -eq 'provider') {
            Assert-RoleTest ($script:Mutations.Count -eq 0 -and $script:ProviderSiteQueries.Count -ge 1) 'Healthy exact-target provider was not verified as a no-op.'
        }
        else {
            Assert-RoleTest (@($script:Mutations | Where-Object Command -eq $family.Expected).Count -eq 1) "Shipped handler did not perform supported $($family.Name) addition."
        }
        Assert-RoleTest ($result.Status -eq 'Completed') "$($family.Name) did not verify native readiness before returning."
        Assert-RoleTest (@($script:Probes | Where-Object { $_ -like '*OLD-BROKEN*' }).Count -eq 0) "$($family.Name) reasserted an unrelated deliberately broken role."
        Assert-RoleTest ($script:SqlQueries[0].DataSource -like '*OLD-SQL.lab.test,5422*') 'SQL prerequisite/readiness dropped the existing nondefault SQL port.'
        if ($family.Name -eq 'secondary') {
            $request = @($script:Mutations | Where-Object Command -eq 'New-CMSecondarySite')[0]
            Assert-RoleTest ($request.Arguments.SiteName -eq 'Explicit secondary' -and $request.Arguments.PrimarySiteCode -eq 'PRI') 'Secondary used the wrong name/parent.'
            Assert-RoleTest ($script:SecondaryPolls -ge 2) 'Queued secondary was released before native activation.'
            Assert-RoleTest ($script:RoleReads['DP|SEC|NEW-ROLE.lab.test'] -ge 2 -and $script:RoleReads['MP|SEC|NEW-ROLE.lab.test'] -ge 2) 'Secondary completion skipped physical DP/MP readiness.'
            Assert-RoleTest (@($script:SqlConnectionTargets | Where-Object { $_ -like '*NEW-ROLE.lab.test\CONFIGMGRSEC;*' }).Count -eq 1) 'Secondary SQL Express completion did not verify CONFIGMGRSEC/CM_SEC.'
        }
        if ($family.Name -eq 'passive') {
            Assert-RoleTest ($script:PassivePolls -ge 3 -and $script:Clock -ge [datetime]'2026-11-23T12:05:00Z') 'New passive completion skipped native activation/stable-ready observation.'
            Assert-RoleTest ($script:PrincipalGrants.Count -eq 0) 'Healthy pre-existing bindings were reasserted unnecessarily.'
        }
        $script:Cases++
    }

    $config = New-RoleTestConfig -Targets @(
        (New-RoleTestVM -Name Z-SOURCE -Properties @{ installDP = $true }),
        (New-RoleTestVM -Name A-PULL -Properties @{ installDP = $true; enablePullDP = $true; pullDPSourceDP = 'Z-SOURCE' })
    )
    $action = @(Get-MemLabsExistingRoleActions $config)[0]
    Reset-RoleTestState $config $action
    $null = Invoke-RoleTestHandler $config $action
    $adds = @($script:Mutations | Where-Object Command -eq 'Add-DP')
    Assert-RoleTest ($adds.Count -eq 2 -and $adds[0].Fqdn -eq 'Z-SOURCE.lab.test') 'New pull-DP source was not installed before its dependent.'
    Assert-RoleTest ($adds[1].Arguments.SourceDistributionPoint -eq 'Z-SOURCE.lab.test' -and $adds[1].Arguments.EnablePullDP) 'Pull-DP source/intent was lost.'
    $script:Cases++

    $config = New-RoleTestConfig -Targets @((New-RoleTestVM -Properties @{ installDP = $true; installMP = $true; installSUP = $true }))
    $config.virtualMachines[0] | Add-Member NoteProperty cmOptions ([pscustomobject]@{ UsePKI = $true })
    $action = @(Get-MemLabsExistingRoleActions $config)[0]
    Reset-RoleTestState $config $action @{ DelayedTarget = $true; PendingRole = 'DP' }
    $result = Invoke-RoleTestHandler $config $action
    Assert-RoleTest ($script:PrereqCalls -gt 3) 'Concurrent requested-target prerequisites were not given a bounded native wait.'
    Assert-RoleTest ($result.Status -eq 'Completed' -and $script:RoleReads['DP|PRI|NEW-ROLE.lab.test'] -ge 4) 'A metadata-only DP was released before consecutive native-ready observations.'
    Assert-RoleTest (@($script:Mutations | Where-Object { $_.Command -eq 'Add-MP' -and $_.Arguments.CommunicationType -eq 'Https' }).Count -eq 1) 'PKI MP addition lost HTTPS.'
    Assert-RoleTest (@($script:Mutations | Where-Object { $_.Command -eq 'Add-SUP' -and $_.Arguments.WsusSSL }).Count -eq 1) 'PKI SUP addition lost WSUS SSL.'
    $script:Cases++

    foreach ($case in @(
            @{ Faults = @{ OwnerRead = $true }; Properties = @{ installDP = $true }; Pattern = '*synthetic owner provider/SQL read failure*' },
            @{ Faults = @{ OwnerService = $true }; Properties = @{ installDP = $true }; Pattern = '*service*Stopped*no service was started/restarted*' },
            @{ Faults = @{ SqlOffline = $true }; Properties = @{ installDP = $true }; Pattern = '*Required SQL prerequisite*OFFLINE*No SQL configuration was changed*' },
            @{ Faults = @{ SqlConnect = $true }; Properties = @{ installDP = $true }; Pattern = '*synthetic SQL login failure*' },
            @{ Faults = @{ SourceDp = $true }; Properties = @{ installDP = $true; enablePullDP = $true; pullDPSourceDP = 'SOURCE' }; Pattern = '*retained source DP*No source-DP repair*' },
            @{ Faults = @{ ReportingAccount = $true }; Properties = @{ installRP = $true }; Pattern = '*reporting account*No account was created or reset*' },
            @{ Faults = @{ TargetPrereq = $true }; Properties = @{ installMP = $true }; Pattern = '*did not become ready*MP producer prerequisites*No repair*' },
            @{ Faults = @{ TargetFeature = $true }; Properties = @{ installDP = $true }; Pattern = '*Phase 3 prerequisite*No feature/account repair*' }
        )) {
        $config = New-RoleTestConfig -Targets @((New-RoleTestVM -Properties $case.Properties))
        $action = @(Get-MemLabsExistingRoleActions $config)[0]
        Reset-RoleTestState $config $action $case.Faults
        Assert-RoleThrows { Invoke-RoleTestHandler $config $action } $case.Pattern
        Assert-RoleTest ($script:Mutations.Count -eq 0 -and $script:NativeMaintenanceCalls.Count -eq 0) 'A prerequisite blocker attempted repair or submission.'
        if ($case.Faults.TargetPrereq) { Assert-RoleTest ($script:PrereqCalls -le 122) 'New-target prerequisite observation exceeded its polling budget.' }
        if ($case.Faults.TargetFeature) { Assert-RoleTest ($script:PrereqCalls -eq 1) 'A proved missing Phase 3 prerequisite burned the wait budget.' }
        $script:Cases++
    }
    foreach ($case in @(
            @{ Faults = @{ ParentMp = $true }; Pattern = '*no healthy MP*No parent MP was installed/repaired*' },
            @{ Faults = @{ SecondarySubmit = $true }; Pattern = '*synthetic secondary submission failure*' }
        )) {
        $config = New-RoleTestConfig -Targets @((New-RoleTestVM -Role Secondary -Properties @{ siteCode = 'SEC'; parentSiteCode = 'PRI' }))
        $action = @(Get-MemLabsExistingRoleActions $config)[0]
        Reset-RoleTestState $config $action $case.Faults
        Assert-RoleThrows { Invoke-RoleTestHandler $config $action } $case.Pattern
        Assert-RoleTest (@($script:Mutations | Where-Object { $_.Fqdn -like 'OLD-*' }).Count -eq 0) 'Secondary fault reconfigured its existing parent.'
        $script:Cases++
    }
    foreach ($case in @(
            @{ Faults = @{ SqlSysadmin = $true }; Pattern = '*cannot prove existing sysadmin access*' },
            @{ Faults = @{ Admin = 'OLD-LIB' }; Pattern = '*OLD-LIB*no old relationship was repaired*' },
            @{ Faults = @{ Remote = 'OLD-SQL' }; Pattern = '*synthetic retained*unreachable*' },
            @{ Faults = @{ LibraryAcl = $true }; Pattern = '*existing library grants*no old principal/ACL was repaired*' }
        )) {
        $config = New-RoleTestConfig -Targets @((New-RoleTestVM -Role PassiveSite -Properties @{ remoteContentLibVM = 'OLD-LIB' }))
        $action = @(Get-MemLabsExistingRoleActions $config)[0]
        Reset-RoleTestState $config $action $case.Faults
        Assert-RoleThrows { Invoke-RoleTestHandler $config $action } $case.Pattern
        Assert-RoleTest ($script:Mutations.Count -eq 0 -and $script:PrincipalGrants.Count -eq 0) 'Passive prerequisite failure repaired a retained node or submitted setup.'
        $script:Cases++
    }
    $config = New-RoleTestConfig -Targets @((New-RoleTestVM -Role PassiveSite -Properties @{ remoteContentLibVM = 'OLD-LIB' }))
    $action = @(Get-MemLabsExistingRoleActions $config)[0]
    Reset-RoleTestState $config $action
    Initialize-TestLibraryMove
    $result = Invoke-RoleTestHandler $config $action
    Assert-RoleTest ($result.Status -eq 'Completed' -and $script:LibraryMovePolls -ge 4) 'Submitted/progress-complete library relocation was released before exact-site, both native pointer strings and Result=0 cutover.'
    Assert-RoleTest (@($script:LibraryCalls | Where-Object Method -eq SetContentLibraryLocation).Count -eq 1) 'Scoped library relocation did not submit exactly one native request.'
    Assert-RoleTest (@($script:Messages | Where-Object { $_ -like '*pause site package processing*' }).Count -eq 1) 'Native relocation package-processing pause was not reported.'
    $script:Cases++

    foreach ($role in @('DP', 'MP', 'SUP', 'RP')) {
        $config = New-RoleTestConfig -Targets @((New-RoleTestVM -Properties @{ "install$role" = $true }))
        $action = @(Get-MemLabsExistingRoleActions $config)[0]
        Reset-RoleTestState $config $action @{ AddRole = $role }
        Assert-RoleThrows { Invoke-RoleTestHandler $config $action } "*synthetic $role submission failure*"
        Assert-RoleTest (@($script:Mutations | Where-Object { $_.Command -eq "Add-$role" }).Count -eq 1) 'Native submission error was retried/masked.'
        $script:Cases++
    }

    $config = New-RoleTestConfig -Targets @(
        (New-RoleTestVM -Name 'OTHER-PRI' -Role Primary -Properties @{ siteCode = 'TWO'; hidden = $true; remoteSQLVM = 'OLD-SQL' }),
        (New-RoleTestVM -Name 'OTHER-DP' -Properties @{ siteCode = 'TWO'; installDP = $true }),
        (New-RoleTestVM -Name 'PRI-DP' -Properties @{ installDP = $true })
    )
    foreach ($action in @(Get-MemLabsExistingRoleActions $config)) {
        Reset-RoleTestState $config $action
        $null = Invoke-RoleTestHandler $config $action
        Assert-RoleTest (@($script:Mutations | Where-Object SiteCode -ne $action.SiteCode).Count -eq 0) 'Handler crossed site ownership.'
    }
    $script:Cases++

    $config = New-RoleTestConfig -Targets @((New-RoleTestVM -Properties @{ installDP = $true }))
    $action = @(Get-MemLabsExistingRoleActions $config)[0]
    Reset-RoleTestState $config $action
    $script:NativeRoles.DP[(Get-TestKey PRI 'NEW-ROLE.lab.test')] = [pscustomobject]@{ SiteCode = 'PRI'; NetworkOSPath = '\\NEW-ROLE.lab.test' }
    $result = Invoke-RoleTestHandler $config $action
    Assert-RoleTest ($result.Status -eq 'Completed' -and $script:Mutations.Count -eq 0) 'An already healthy explicit role was reasserted.'
    $script:Faults.RoleNotReady = 'DP'
    Assert-RoleThrows { Invoke-RoleTestHandler $config $action } '*Requested existing DP*No role recovery*'
    Assert-RoleTest ($script:Mutations.Count -eq 0) 'An existing broken requested role entered broad recovery.'
    $script:Cases++

    $forged = $action.Payload | ConvertFrom-Json
    $forged.Targets[0].vmName = 'OLD-BROKEN'
    $action.Payload = $forged | ConvertTo-Json -Depth 20 -Compress
    Reset-RoleTestState $config $action
    Assert-RoleThrows { Invoke-RoleTestHandler $config $action } '*dependency context, not a requested deployment target*'
    Assert-RoleTest ($script:Mutations.Count -eq 0 -and $script:SqlQueries.Count -eq 0) 'Forged dependency target reached a native operation.'
    $script:Cases++

    foreach ($instance in @('MSSQLSERVER', 'SECINST')) {
        $config = New-RoleTestConfig -Targets @((New-RoleTestVM -Role Secondary -Properties @{
                        siteCode = 'SEC'; parentSiteCode = 'PRI'; sqlVersion = 'SQL2022'; sqlInstanceName = $instance; sqlPort = 5411
                    }))
        $config.virtualMachines[0] | Add-Member NoteProperty cmOptions ([pscustomobject]@{ UsePKI = $true })
        $action = @(Get-MemLabsExistingRoleActions $config)[0]
        Reset-RoleTestState $config $action
        $result = Invoke-RoleTestHandler $config $action
        $request = @($script:Mutations | Where-Object Command -eq 'New-CMSecondarySite')[0]
        Assert-RoleTest ($request.Arguments.Https -and $request.Arguments.ImportCertificate) 'PKI secondary addition lost its certificate inputs.'
        Assert-RoleTest ($request.Arguments.CertificatePassword -is [Security.SecureString]) 'Secondary credentials were not kept in-memory as a SecureString.'
        Assert-RoleTest ($request.Arguments.SqlServerSetting.UseExistingSqlServerInstance) 'Secondary with full SQL fell back to SQL Express.'
        Assert-RoleTest (@($script:SqlConnectionTargets | Where-Object { $_ -like '*NEW-ROLE.lab.test*,5411;*' }).Count -ge 1) 'Secondary preinstalled-SQL prerequisite lost its named/default instance port.'
        Assert-RoleTest ($result.Status -eq 'Completed' -and $script:SecondaryPolls -ge 2) 'New full-SQL secondary skipped native activation/readiness.'
        $script:Cases++
    }

    $config = New-RoleTestConfig -Targets @((New-RoleTestVM -Role Secondary -Properties @{
                    siteCode = 'SEC'; parentSiteCode = 'PRI'; installSUP = $true
                }))
    $action = @(Get-MemLabsExistingRoleActions $config)[0]
    Reset-RoleTestState $config $action @{ SecondaryActive = $true }
    $script:NativeRoles.SUP[(Get-TestKey PRI 'OLD-PRI.lab.test')] = [pscustomobject]@{ SiteCode = 'PRI'; NetworkOSPath = '\\OLD-PRI.lab.test' }
    $null = Invoke-RoleTestHandler $config $action
    Assert-RoleTest (@($script:Mutations | Where-Object { $_.Command -eq 'Add-SUP' -and $_.SiteCode -eq 'SEC' }).Count -eq 1) 'A new secondary SUP was omitted or installed in its parent site.'
    Assert-RoleTest (@($script:Mutations | Where-Object { $_.Fqdn -like 'OLD-*' }).Count -eq 0) 'Secondary SUP setup reasserted the parent SUP.'
    $script:Cases++

    $config = New-RoleTestConfig -Targets @(
        (New-RoleTestVM -Name OLD-SEC -Role Secondary -Properties @{ hidden = $true; siteCode = 'SEC'; parentSiteCode = 'PRI' }),
        (New-RoleTestVM -Properties @{ siteCode = 'SEC'; installDP = $true })
    )
    $action = @(Get-MemLabsExistingRoleActions $config)[0]
    Reset-RoleTestState $config $action
    $null = Invoke-RoleTestHandler $config $action
    Assert-RoleTest (@($script:Mutations | Where-Object { $_.Command -eq 'Add-DP' -and $_.SiteCode -eq 'SEC' }).Count -eq 1) 'An existing secondary-owned remote DP was routed to the wrong site.'
    $script:Cases++

    $config = New-RoleTestConfig -Targets @((New-RoleTestVM -Role Secondary -Properties @{ siteCode = 'SEC'; parentSiteCode = 'PRI' }))
    $action = @(Get-MemLabsExistingRoleActions $config)[0]
    Reset-RoleTestState $config $action
    $script:Sites.SEC = [pscustomobject]@{ SiteCode = 'SEC'; Type = 1; Status = 3; ServerName = 'NEW-ROLE.lab.test'; ReportingSiteCode = 'PRI' }
    Assert-RoleThrows { Invoke-RoleTestHandler $config $action } '*secondary*failed/unknown Status=3*No recovery*'
    Assert-RoleTest ($script:Mutations.Count -eq 0) 'An already failed secondary triggered recovery/reinstallation.'
    $script:Cases++

    foreach ($state in @(196611, 131071)) {
        $config = New-RoleTestConfig -Targets @((New-RoleTestVM -Role PassiveSite -Properties @{ remoteContentLibVM = 'OLD-LIB' }))
        $action = @(Get-MemLabsExistingRoleActions $config)[0]
        Reset-RoleTestState $config $action
        $script:PassiveNodes = @([pscustomobject]@{ NetworkOSPath = '\\NEW-ROLE.lab.test'; SiteCode = 'PRI'; ServerState = $state })
        if ($state -eq 196611) {
            $result = Invoke-RoleTestHandler $config $action
            Assert-RoleTest ($result.Status -eq 'Completed' -and $script:Clock -ge [datetime]'2026-11-23T12:05:00Z') 'Existing passive completion skipped the native stable-ready observation.'
        }
        else { Assert-RoleThrows { Invoke-RoleTestHandler $config $action } '*passive*not stably Ready*No RetryInstallation*' }
        Assert-RoleTest ($script:Mutations.Count -eq 0) 'Existing passive observation issued installation/recovery.'
        $script:Cases++
    }
    $config = New-RoleTestConfig -Targets @((New-RoleTestVM -Role PassiveSite -Properties @{ remoteContentLibVM = 'OLD-LIB' }))
    $action = @(Get-MemLabsExistingRoleActions $config)[0]
    Reset-RoleTestState $config $action @{ DelayedPassiveAdk = $true }
    $null = Invoke-RoleTestHandler $config $action
    Assert-RoleTest ($script:AdkPaths -ge 4) 'Passive setup did not observe concurrent requested-node ADK preparation.'
    $script:Cases++

    foreach ($brokenUpstream in @($false, $true)) {
        $config = New-RoleTestConfig -Targets @((New-RoleTestVM -Properties @{ installSUP = $true }))
        $config.virtualMachines[0] | Add-Member NoteProperty parentSiteCode CAS
        $action = @(Get-MemLabsExistingRoleActions $config)[0]
        $faults = @{}
        if ($brokenUpstream) { $faults.RoleNotReady = 'SUP' }
        Reset-RoleTestState $config $action $faults
        $script:Sites.PRI.ReportingSiteCode = 'CAS'
        $script:Sites.CAS = [pscustomobject]@{ SiteCode = 'CAS'; Status = 1; ServerName = 'OLD-CAS.lab.test'; ReportingSiteCode = '' }
        $script:NativeRoles.SUP[(Get-TestKey CAS 'CAS-SUP.lab.test')] = [pscustomobject]@{ SiteCode = 'CAS'; NetworkOSPath = '\\CAS-SUP.lab.test' }
        if ($brokenUpstream) {
            Assert-RoleThrows { Invoke-RoleTestHandler $config $action } '*selected*not verified ready*'
            Assert-RoleTest ($script:Mutations.Count -eq 0) 'Broken required CAS SUP triggered configuration/repair.'
        }
        else {
            $null = Invoke-RoleTestHandler $config $action
            Assert-RoleTest (@($script:Mutations | Where-Object SiteCode -ne PRI).Count -eq 0) 'A healthy CAS prerequisite caused CAS mutations.'
        }
        $script:Cases++
    }
    foreach ($selectedBroken in @($false, $true)) {
        $config = New-RoleTestConfig -Targets @((New-RoleTestVM -Properties @{ installSUP = $true }))
        $config.virtualMachines[0] | Add-Member NoteProperty parentSiteCode CAS
        $action = @(Get-MemLabsExistingRoleActions $config)[0]
        Reset-RoleTestState $config $action @{ SelectedUpstreamBroken = $selectedBroken; UnrelatedSup = $true }
        $script:Sites.PRI.ReportingSiteCode = 'CAS'
        $script:Sites.CAS = [pscustomobject]@{ SiteCode = 'CAS'; Status = 1; ServerName = 'OLD-CAS.lab.test'; ReportingSiteCode = '' }
        $script:NativeRoles.SUP[(Get-TestKey CAS 'CAS-SUP.lab.test')] = [pscustomobject]@{ SiteCode = 'CAS'; NetworkOSPath = '\\CAS-SUP.lab.test' }
        $script:NativeRoles.SUP[(Get-TestKey CAS 'ALTERNATE.lab.test')] = [pscustomobject]@{ SiteCode = 'CAS'; NetworkOSPath = '\\ALTERNATE.lab.test' }
        if ($selectedBroken) {
            Assert-RoleThrows { Invoke-RoleTestHandler $config $action } '*selected*not verified ready*'
            Assert-RoleTest ($script:Mutations.Count -eq 0) 'An alternate healthy SUP permitted mutation when the selected endpoint was broken.'
        }
        else { $null = Invoke-RoleTestHandler $config $action }
        Assert-RoleTest (@($script:Probes | Where-Object { $_ -like '*ALTERNATE*' }).Count -eq 0) 'Unrelated SUP substituted for the selected endpoint.'
        $script:Cases++
    }
    $config = New-RoleTestConfig
    $sql = @($config.virtualMachines | Where-Object vmName -eq 'OLD-SQL')[0]
    $sql.siteCode = ''
    $sql | Add-Member NoteProperty ExistingVM $true
    $action = @(Get-MemLabsExistingRoleActions $config)[0]
    Reset-RoleTestState $config $action
    $null = Invoke-RoleTestHandler $config $action
    Assert-RoleTest (@($script:Mutations | Where-Object { $_.Command -eq 'Add-RP' -and $_.Fqdn -eq 'OLD-SQL.lab.test' -and $_.SiteCode -eq 'PRI' }).Count -eq 1) 'Explicit remote-SQL RP without a siteCode was not installed for its unique owner.'
    $script:Cases++

    $config = New-RoleTestConfig -Targets @((New-RoleTestVM -Properties @{ installDP = $true }))
    $config.virtualMachines[0] | Add-Member NoteProperty cmOptions ([pscustomobject]@{ UsePKI = $true })
    $action = @(Get-MemLabsExistingRoleActions $config)[0]
    Reset-RoleTestState $config $action @{ PkiInput = $true }
    Assert-RoleThrows { Invoke-RoleTestHandler $config $action } '*Required existing PKI input is missing*No certificate repair/export*'
    Assert-RoleTest ($script:Mutations.Count -eq 0) 'A missing retained PKI input caused certificate repair/export.'
    $script:Cases++

    foreach ($readDenied in @($false, $true)) {
        $config = New-RoleTestConfig -Targets @((New-RoleTestVM -Properties @{
                        installDP = $true; enablePullDP = $true; pullDPSourceDP = 'SOURCE'
                    }))
        $action = @(Get-MemLabsExistingRoleActions $config)[0]
        $faults = @{}
        if ($readDenied) { $faults.SourceRead = $true }
        Reset-RoleTestState $config $action $faults
        $script:NativeRoles.DP[(Get-TestKey PRI 'SOURCE.lab.test')] = [pscustomobject]@{ SiteCode = 'PRI'; NetworkOSPath = '\\SOURCE.lab.test' }
        if ($readDenied) {
            Assert-RoleThrows { Invoke-RoleTestHandler $config $action } '*retained source DP*synthetic retained source access denied*No source-DP repair*'
            Assert-RoleTest ($script:Mutations.Count -eq 0) 'Denied retained-source read triggered repair/submission.'
        }
        else {
            $result = Invoke-RoleTestHandler $config $action
            Assert-RoleTest ($result.Status -eq 'Completed' -and @($script:Mutations | Where-Object Command -eq 'Add-DP').Count -eq 1) 'Read-only retained-source validation did not permit a healthy pull-DP addition.'
        }
        Assert-RoleTest ($script:SourceReadPaths.Count -gt 0) 'The shipped retained-source read probe was not executed.'
        $script:Cases++
    }

    foreach ($case in @(
            @{ Role = 'SiteSystem'; Properties = @{ installDP = $true }; Faults = @{ PendingForever = 'DP' }; Pattern = '*did not become ready*DP physical readiness*' },
            @{ Role = 'Secondary'; Properties = @{ siteCode = 'SEC'; parentSiteCode = 'PRI' }; Faults = @{ PendingSecondary = $true }; Pattern = '*did not become ready*native secondary*activation*' },
            @{ Role = 'Secondary'; Properties = @{ siteCode = 'SEC'; parentSiteCode = 'PRI' }; Faults = @{ SecondarySqlOffline = $true }; Pattern = '*SQL prerequisite*CM_SEC*OFFLINE*' },
            @{ Role = 'Secondary'; Properties = @{ siteCode = 'SEC'; parentSiteCode = 'PRI' }; Faults = @{ DrsFailed = $true }; Pattern = '*DRS link is failed/degraded*No DRS reinitialization*' },
            @{ Role = 'Secondary'; Properties = @{ siteCode = 'SEC'; parentSiteCode = 'PRI' }; Faults = @{ DrsMissing = $true; DrsSqlHealthy = $true }; Pattern = '*did not become ready*secondary*DRS readiness*' },
            @{ Role = 'Secondary'; Properties = @{ siteCode = 'SEC'; parentSiteCode = 'PRI' }; Faults = @{ DrsRead = $true }; Pattern = '*synthetic DRS provider failure*' },
            @{ Role = 'PassiveSite'; Properties = @{ remoteContentLibVM = 'OLD-LIB' }; Faults = @{ PassiveFailed = $true }; Pattern = '*passive*not stably Ready*No RetryInstallation*' },
            @{ Role = 'PassiveSite'; Properties = @{ remoteContentLibVM = 'OLD-LIB' }; Faults = @{ PendingPassive = $true }; Pattern = '*did not become ready*passive*stably Ready*' }
        )) {
        $config = New-RoleTestConfig -Targets @((New-RoleTestVM -Role $case.Role -Properties $case.Properties))
        $action = @(Get-MemLabsExistingRoleActions $config)[0]
        Reset-RoleTestState $config $action $case.Faults
        Assert-RoleThrows { Invoke-RoleTestHandler $config $action } $case.Pattern
        Assert-RoleTest ($script:Mutations.Count -gt 0) 'Native-completion fixture did not actually submit its new role/site.'
        Assert-RoleTest (@($script:Mutations | Where-Object { $_.Fqdn -like 'OLD-*' }).Count -eq 0) 'Incomplete native setup triggered repair on an existing node.'
        $script:Cases++
    }
    $config = New-RoleTestConfig -Targets @((New-RoleTestVM -Role Secondary -Properties @{ siteCode = 'SEC'; parentSiteCode = 'PRI' }))
    $action = @(Get-MemLabsExistingRoleActions $config)[0]
    Reset-RoleTestState $config $action @{ DrsFailed = $true; DrsSqlHealthy = $true }
    Assert-RoleThrows { Invoke-RoleTestHandler $config $action } '*DRS link is failed/degraded*Aggregate SQL state cannot prove requested-link readiness*'
    Assert-RoleTest ($script:NativeMaintenanceCalls.Count -eq 0) 'Bad requested-link state consulted an unproven aggregate SQL fallback.'
    $script:Cases++

    foreach ($case in @(
            @{ Locations = @(); Faults = @{}; Cause = 'found 0*' },
            @{ Locations = @(); Faults = @{ ProviderRead = $true }; Cause = 'synthetic provider read failure*' },
            @{ Locations = @([pscustomobject]@{ Machine = 'Z-PROVIDER.lab.test'; SiteCode = 'PRI' }); Faults = @{ ProviderNamespace = $true }; Cause = 'synthetic target provider namespace failure*' },
            @{ Locations = @([pscustomobject]@{ Machine = 'Z-PROVIDER.lab.test'; SiteCode = 'PRI' }); Faults = @{ ProviderSiteMismatch = $true }; Cause = 'cannot read Active site*' },
            @{ Locations = @([pscustomobject]@{ Machine = 'Z-PROVIDER.lab.test'; SiteCode = 'PRI' }); Faults = @{ ProviderInactive = $true }; Cause = 'cannot read Active site*' },
            @{ Locations = @([pscustomobject]@{ Machine = 'Z-PROVIDER.lab.test'; SiteCode = 'TWO' }); Faults = @{}; Cause = 'found 1*' },
            @{ Locations = @(
                    [pscustomobject]@{ Machine = 'Z-PROVIDER.lab.test'; SiteCode = 'PRI' },
                    [pscustomobject]@{ Machine = 'Z-PROVIDER.lab.test'; SiteCode = 'PRI' }
                ); Faults = @{}; Cause = 'found 2*' }
        )) {
        $config = New-RoleTestConfig -Targets @(
            (New-RoleTestVM -Name A-ROLES -Properties @{ installDP = $true; installMP = $true; installSUP = $true; installRP = $true }),
            (New-RoleTestVM -Name B-SECONDARY -Role Secondary -Properties @{ siteCode = 'SEC'; parentSiteCode = 'PRI' }),
            (New-RoleTestVM -Name C-PASSIVE -Role PassiveSite -Properties @{ remoteContentLibVM = 'OLD-LIB' }),
            (New-RoleTestVM -Name Z-PROVIDER -Properties @{ hidden = $true; ExistingVM = $true; installSMSProv = $true })
        )
        $action = @(Get-MemLabsExistingRoleActions $config)[0]
        Reset-RoleTestState $config $action $case.Faults
        $script:Faults.NewBindingsMissing = $true
        $script:Providers = $case.Locations
        Assert-RoleThrows { Invoke-RoleTestHandler $config $action } `
            "*Product-safety blocker*Z-PROVIDER.lab.test*$($case.Cause)Native provider addition requires broader site maintenance and cannot be run under preservation policy*"
        Assert-RoleTest ($script:Mutations.Count -eq 0 -and $script:PrincipalGrants.Count -eq 0) 'Provider product-safety blocker did not precede all other role/secondary/passive mutations in its batch.'
        Assert-RoleTest ($script:NativeMaintenanceCalls.Count -eq 0) 'Provider product-safety blocker invoked setup, service control, or native site maintenance.'
        Assert-RoleTest ($script:PrereqCalls -eq 0 -and $script:SqlQueries.Count -eq 0) 'Provider product-safety preflight ran after mutation-capable producer prerequisite helpers.'
        $script:Cases++
    }

    $config = New-RoleTestConfig -Targets @(
        (New-RoleTestVM -Name A-DP -Properties @{ installDP = $true }),
        (New-RoleTestVM -Name Z-PROVIDER -Properties @{ hidden = $true; ExistingVM = $true; installSMSProv = $true })
    )
    $action = @(Get-MemLabsExistingRoleActions $config)[0]
    Reset-RoleTestState $config $action
    $script:Providers = @([pscustomobject]@{ Machine = 'Z-PROVIDER.lab.test'; SiteCode = 'PRI' })
    $result = Invoke-RoleTestHandler $config $action
    Assert-RoleTest ($result.Status -eq 'Completed') 'Healthy exact-target provider verification blocked an otherwise supported DP addition.'
    Assert-RoleTest (@($script:Mutations | Where-Object Command -eq 'Add-DP').Count -eq 1 -and
        @($script:Mutations | Where-Object Fqdn -ne 'A-DP.lab.test').Count -eq 0) 'Healthy provider verification performed unrelated maintenance/mutations.'
    Assert-RoleTest ($script:ProviderSiteQueries.Count -eq 2) 'Healthy provider was not verified both before the batch and before completion.'
    Assert-RoleTest ($script:NativeMaintenanceCalls.Count -eq 0) 'Healthy provider no-op invoked setup/service/native maintenance.'
    $script:Cases++

    foreach ($loginAlreadyExists in @($false, $true)) {
        $config = New-RoleTestConfig -Targets @((New-RoleTestVM -Role PassiveSite -Properties @{ remoteContentLibVM = 'OLD-LIB' }))
        $action = @(Get-MemLabsExistingRoleActions $config)[0]
        Reset-RoleTestState $config $action @{ NewBindingsMissing = $true; NewLoginExists = $loginAlreadyExists }
        $result = Invoke-RoleTestHandler $config $action
        Assert-RoleTest ($result.Status -eq 'Completed') 'Missing bindings for the genuinely new passive computer were treated as broken old baseline.'
        Assert-RoleTest (@($script:PrincipalGrants | Where-Object Kind -eq Sql).Count -eq 1) 'New passive SQL login/sysadmin binding was not provisioned exactly once.'
        Assert-RoleTest (@($script:PrincipalGrants | Where-Object Kind -eq Admin).Count -eq 3) 'New passive administrator bindings did not cover only its required existing owner/SQL/library endpoints.'
        Assert-RoleTest (@($script:PrincipalGrants | Where-Object Kind -eq Share).Count -eq 1 -and
            @($script:PrincipalGrants | Where-Object Kind -eq Ntfs).Count -eq 1) 'New passive share/NTFS access was not provisioned narrowly.'
        Assert-RoleTest (@($script:PrincipalGrants | Where-Object Account -ne 'LAB\NEW-ROLE$').Count -eq 0) 'Provisioning changed an old principal.'
        $grantCount = $script:PrincipalGrants.Count
        $null = Invoke-RoleTestHandler $config $action
        Assert-RoleTest ($script:PrincipalGrants.Count -eq $grantCount) 'Healthy completed passive verification reasserted existing bindings.'
        $script:Cases++
    }

    foreach ($faults in @(
            @{ NewBindingsMissing = $true; Trust = 'OLD-SQL' },
            @{ NewBindingsMissing = $true; DependencyService = 'OLD-LIB' },
            @{ NewBindingsMissing = $true; Admin = 'OLD-LIB' },
            @{ NewBindingsMissing = $true; LibraryAcl = $true },
            @{ NewBindingsMissing = $true; LibraryDeny = $true },
            @{ NewBindingsMissing = $true; SqlSidConflict = 'OLD-PRI' },
            @{ SqlSidConflict = 'NEW-ROLE' }
        )) {
        $config = New-RoleTestConfig -Targets @((New-RoleTestVM -Role PassiveSite -Properties @{ remoteContentLibVM = 'OLD-LIB' }))
        $action = @(Get-MemLabsExistingRoleActions $config)[0]
        Reset-RoleTestState $config $action $faults
        Assert-RoleThrows { Invoke-RoleTestHandler $config $action } '*existing*'
        Assert-RoleTest ($script:Mutations.Count -eq 0 -and $script:PrincipalGrants.Count -eq 0) 'Broken old trust/service/access/SID relationship was healed or provisioned around.'
        Assert-RoleTest ($script:NativeMaintenanceCalls.Count -eq 0) 'Old baseline blocker triggered broad maintenance.'
        $script:Cases++
    }

    foreach ($alreadyRegistered in @($false, $true)) {
        $properties = @{ remoteContentLibVM = 'OLD-LIB' }
        if (-not $alreadyRegistered) { $properties.hidden = $true; $properties.ExistingVM = $true }
        $config = New-RoleTestConfig -Targets @((New-RoleTestVM -Role PassiveSite -Properties $properties))
        $action = @(Get-MemLabsExistingRoleActions $config)[0]
        Reset-RoleTestState $config $action @{ NewBindingsMissing = $true }
        if ($alreadyRegistered) {
            $script:PassiveNodes = @([pscustomobject]@{ NetworkOSPath = '\\NEW-ROLE.lab.test'; SiteCode = 'PRI'; ServerState = 196611 })
        }
        Assert-RoleThrows { Invoke-RoleTestHandler $config $action } '*cannot prove existing sysadmin access*'
        Assert-RoleTest ($script:PrincipalGrants.Count -eq 0) 'An existing target/passive relationship was mistaken for a new-computer provisioning request.'
        $script:Cases++
    }
    $config = New-RoleTestConfig -Targets @((New-RoleTestVM -Role PassiveSite -Properties @{ remoteContentLibVM = 'OLD-LIB' }))
    $action = @(Get-MemLabsExistingRoleActions $config)[0]
    Reset-RoleTestState $config $action @{ NewBindingsMissing = $true }
    $script:NativeRoles.DP[(Get-TestKey PRI 'OLD-PRI.lab.test')] = [pscustomobject]@{ SiteCode = 'PRI'; NetworkOSPath = '\\OLD-PRI.lab.test' }
    Assert-RoleThrows { Invoke-RoleTestHandler $config $action } '*still hosts a DP*Removing an existing DP is not authorized*'
    Assert-RoleTest ($script:PrincipalGrants.Count -eq 0 -and $script:Mutations.Count -eq 0) 'HA prerequisite silently removed/repaired an existing active-site DP.'
    $script:Cases++

    $config = New-RoleTestConfig -Targets @((New-RoleTestVM -Role PassiveSite -Properties @{ remoteContentLibVM = 'OLD-LIB' }))
    $sql = @($config.virtualMachines | Where-Object vmName -eq 'OLD-SQL')[0]
    $sql.role = 'SQLAO'
    $sql | Add-Member NoteProperty AlwaysOnListenerName 'CM-LISTENER'
    $sql | Add-Member NoteProperty OtherNode 'OLD-SQL2'
    $config.virtualMachines += New-RoleTestVM -Name OLD-SQL2 -Role SQLAO -Properties @{
        hidden = $true; OtherNode = 'OLD-SQL'; sqlInstanceName = 'MSSQLSERVER'; sqlPort = 6433
    }
    $action = @(Get-MemLabsExistingRoleActions $config)[0]
    Reset-RoleTestState $config $action @{ NewBindingsMissing = $true }
    $result = Invoke-RoleTestHandler $config $action
    $sqlEndpoints = @($script:PrincipalGrants | Where-Object Kind -eq Sql | ForEach-Object Endpoint | Sort-Object)
    Assert-RoleTest ($result.Status -eq 'Completed' -and ($sqlEndpoints -join ',') -eq 'OLD-SQL.lab.test,OLD-SQL2.lab.test') 'New passive SQLAO computer grants were not scoped to both configured physical replicas.'
    Assert-RoleTest (@($script:PrincipalGrants | Where-Object { $_.Endpoint -like '*LISTENER*' -or $_.Account -ne 'LAB\NEW-ROLE$' }).Count -eq 0) 'SQLAO provisioning changed an old principal or relied on a listener-only grant.'
    $script:Cases++

    $config = New-RoleTestConfig -Targets @((New-RoleTestVM -Role PassiveSite -Properties @{ remoteContentLibVM = 'OLD-LIB' }))
    $action = @(Get-MemLabsExistingRoleActions $config)[0]
    Reset-RoleTestState $config $action @{ LibraryFreshDestinationAccess = $true }
    Initialize-TestLibraryMove
    $script:LibraryShareExists = $false
    $script:LibraryRootExists = $false
    $script:LibraryFolderExists = $false
    $result = Invoke-RoleTestHandler $config $action
    Assert-RoleTest ($result.Status -eq 'Completed' -and $script:LibraryChanges -contains 'NewShare') 'Fresh explicitly selected destination was not provisioned for the requested move.'
    Assert-RoleTest (($script:LibraryShareAccounts -join ',') -eq 'LAB\OLD-PRI$,LAB\NEW-ROLE$') 'Fresh destination omitted active/passive access or broadened unrelated principals.'
    $script:Cases++

    $config = New-RoleTestConfig -Targets @((New-RoleTestVM -Role PassiveSite -Properties @{ remoteContentLibVM = 'OLD-LIB' }))
    $action = @(Get-MemLabsExistingRoleActions $config)[0]
    Reset-RoleTestState $config $action
    Initialize-TestLibraryMove
    $script:Sites.PRI.ContentLibraryLocation = $script:LibraryDestination
    $script:LibraryMoveActive = $true
    $script:LibraryResult = 131078
    $result = Invoke-RoleTestHandler $config $action
    Assert-RoleTest ($result.Status -eq 'Completed' -and @($script:LibraryCalls | Where-Object Method -eq SetContentLibraryLocation).Count -eq 0) 'Attributable same-site/destination pending move was resubmitted instead of observed.'
    Assert-RoleTest ($script:LibraryChanges.Count -eq 0) 'Pending relocation resume adopted or rewrote destination files.'
    $script:Cases++

    foreach ($case in @(
            @{ Faults = @{ LibraryPopulated = $true }; Pattern = '*NEW/EMPTY*'; Submissions = 0 },
            @{ Faults = @{ LibrarySourceBroken = $true }; Pattern = '*existing library source is unreadable*'; Submissions = 0 },
            @{ Faults = @{ LibraryMissingResult = $true }; Pattern = '*PRESENT Result*'; Submissions = 0 },
            @{ Faults = @{ LibraryMissingResultAfterSubmit = $true }; Pattern = '*PRESENT Result*left running*'; Submissions = 1 },
            @{ Faults = @{ LibrarySetFailure = $true }; Pattern = '*ReturnValue=*5*not retried*'; Submissions = 1 },
            @{ Faults = @{ LibraryNeverCutover = $true }; Pattern = '*not certified complete*cutover*left running*'; Submissions = 1 },
            @{ Faults = @{ LibraryWrongSite = $true }; Pattern = '*not certified complete*cutover*left running*'; Submissions = 1 }
        )) {
        $config = New-RoleTestConfig -Targets @((New-RoleTestVM -Role PassiveSite -Properties @{ remoteContentLibVM = 'OLD-LIB' }))
        $action = @(Get-MemLabsExistingRoleActions $config)[0]
        Reset-RoleTestState $config $action $case.Faults
        Initialize-TestLibraryMove
        Assert-RoleThrows { Invoke-RoleTestHandler $config $action } $case.Pattern
        Assert-RoleTest (@($script:LibraryCalls | Where-Object Method -eq SetContentLibraryLocation).Count -eq $case.Submissions) 'Failed/unfinished relocation was submitted or automatically retried unexpectedly.'
        Assert-RoleTest (@($script:Mutations | Where-Object Command -eq Add-CMPassiveSite).Count -eq 0) 'Passive setup proceeded without certified library cutover.'
        Assert-RoleTest ($script:NativeMaintenanceCalls.Count -eq 0) 'Relocation failure triggered setup/service/repair/cancellation fallback.'
        $script:Cases++
    }

    foreach ($blocker in @('OtherPending', 'OtherSiteCollision', 'ActiveDP')) {
        $config = New-RoleTestConfig -Targets @((New-RoleTestVM -Role PassiveSite -Properties @{ remoteContentLibVM = 'OLD-LIB' }))
        $action = @(Get-MemLabsExistingRoleActions $config)[0]
        Reset-RoleTestState $config $action
        Initialize-TestLibraryMove
        $pattern = '*different or unattributable*pending*'
        if ($blocker -eq 'OtherPending') { $script:LibraryResult = 131078 }
        elseif ($blocker -eq 'OtherSiteCollision') {
            $script:Sites.TWO = [pscustomobject]@{ SiteCode = 'TWO'; ServerName = 'OTHER-PRI.lab.test'; ContentLibraryLocation = $script:LibraryDestination }
            $pattern = '*collides with site*TWO*'
        }
        else {
            $script:NativeRoles.DP[(Get-TestKey PRI 'OLD-PRI.lab.test')] = [pscustomobject]@{ SiteCode = 'PRI'; NetworkOSPath = '\\OLD-PRI.lab.test' }
            $pattern = '*still hosts a DP*'
        }
        Assert-RoleThrows { Invoke-RoleTestHandler $config $action } $pattern
        Assert-RoleTest (@($script:LibraryCalls | Where-Object Method -eq SetContentLibraryLocation).Count -eq 0 -and
            $script:LibraryChanges.Count -eq 0 -and $script:PrincipalGrants.Count -eq 0) 'Existing move/site/DP conflict caused a relocation, destination mutation or baseline repair.'
        $script:Cases++
    }
    foreach ($overlap in @('Source', 'AliasShare')) {
        $config = New-RoleTestConfig -Targets @((New-RoleTestVM -Role PassiveSite -Properties @{ remoteContentLibVM = 'OLD-LIB' }))
        $action = @(Get-MemLabsExistingRoleActions $config)[0]
        Reset-RoleTestState $config $action @{ LibraryShareAlias = $true }
        Initialize-TestLibraryMove
        $pattern = '*not provably disjoint*'
        if ($overlap -eq 'Source') {
            $script:Sites.PRI.ContentLibraryLocation = "$script:LibraryDestination\Nested"
            $script:LibraryPointer = "$script:LibraryDestination\Nested"
            $script:LibraryDrives = $script:LibraryPointer
            $script:LibraryResult = 0
        }
        else {
            $script:Sites.TWO = [pscustomobject]@{ SiteCode = 'TWO'; ServerName = 'OTHER-PRI.lab.test'; ContentLibraryLocation = '\\OLD-LIB\ALIAS\ContentLib' }
            $pattern = '*filesystem overlaps source/other site*TWO*'
        }
        Assert-RoleThrows { Invoke-RoleTestHandler $config $action } $pattern
        Assert-RoleTest (@($script:LibraryCalls | Where-Object Method -eq SetContentLibraryLocation).Count -eq 0 -and
            $script:LibraryChanges.Count -eq 0) 'Overlapping source or another site library was reserved or submitted.'
        $script:Cases++
    }
}

Write-Host "PASS -- existing-hierarchy role actions: $script:Cases cases, $script:Assertions assertions; mode=$Mode; PowerShell $($PSVersionTable.PSVersion)."
