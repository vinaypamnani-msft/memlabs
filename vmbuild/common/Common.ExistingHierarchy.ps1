function Get-MemLabsExistingHierarchyActions {
    param([Parameter(Mandatory)]$DeployConfig)

    $actions = [Collections.Generic.List[object]]::new()
    foreach ($group in @(Get-MemLabsExistingClientPushPlan -DeployConfig $DeployConfig | Group-Object OwnerVMName)) {
        $actions.Add([pscustomobject]@{
                Kind = 'ClientPush'; OwnerVMName = $group.Name; SiteCode = "$($group.Group[0].SiteCode)"
                TargetVMNames = @($group.Group.ClientVMName | Select-Object -Unique)
                TimeoutSeconds = 180
            })
    }
    foreach ($factory in @('Get-MemLabsExistingRoleActions', 'Get-MemLabsExistingOsdActions', 'Get-MemLabsExistingBitLockerActions')) {
        foreach ($action in @(& $factory -DeployConfig $DeployConfig)) { $actions.Add($action) }
    }
    $requested = @(Get-MemLabsRequestedDeploymentVMs -DeployConfig $DeployConfig | ForEach-Object { "$($_.vmName)" })
    foreach ($action in $actions) {
        if ($action.Kind -notin @('ClientPush', 'SiteRoles', 'Osd', 'BitLocker')) { throw "Unknown existing-hierarchy action '$($action.Kind)'." }
        $owners = @($DeployConfig.virtualMachines | Where-Object { $_.vmName -eq $action.OwnerVMName })
        if ($owners.Count -ne 1 -or -not (Test-MemLabsContextOnlyVM -VM $owners[0]) -or
            "$($owners[0].siteCode)" -ne "$($action.SiteCode)") {
            throw "Existing action '$($action.Kind)' has no unique context-only owner/site."
        }
        $targets = @($action.TargetVMNames)
        if ($targets.Count -eq 0 -or @($targets | Where-Object { -not $_ -or $_ -notin $requested }).Count -gt 0) {
            throw "Existing action '$($action.Kind)' includes a VM that was not requested."
        }
        if ($action.Kind -ne 'ClientPush') {
            if ($action.Handler -isnot [scriptblock]) { throw "Existing action '$($action.Kind)' has no shipped handler." }
            $action | Add-Member -NotePropertyName HandlerText -NotePropertyValue $action.Handler.ToString() -Force
            $action.PSObject.Properties.Remove('Handler')
        }
        if ($action.PSObject.Properties['HostPreflight']) {
            if ($action.HostPreflight -isnot [scriptblock]) { throw "Existing action '$($action.Kind)' has an invalid read-only host preflight." }
            $action | Add-Member -NotePropertyName HostPreflightText -NotePropertyValue $action.HostPreflight.ToString() -Force
            $action.PSObject.Properties.Remove('HostPreflight')
        }
        $timeout = if ($action.PSObject.Properties['TimeoutSeconds']) { $action.TimeoutSeconds } else { 7200 }
        $parsed = 0
        if (-not [int]::TryParse("$timeout", [ref]$parsed) -or $parsed -lt 1 -or $parsed -gt 7200) {
            throw "Existing action '$($action.Kind)' has an invalid bounded timeout."
        }
        $action | Add-Member -NotePropertyName TimeoutSeconds -NotePropertyValue $parsed -Force
        $action
    }
}

function Get-MemLabsExistingActionSupportSource {
    $phaseRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'DSC\phases'
    $files = [ordered]@{}
    foreach ($file in @('ProcessFunctions.ps1', 'ScriptFunctions.ps1')) {
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $phaseRoot $file), [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw "Existing-action support '$file' has parse errors: $($errors -join '; ')" }
        $functions = @($ast.EndBlock.Statements | Where-Object {
                $_ -is [Management.Automation.Language.FunctionDefinitionAst]
            })
        if ($functions.Count -eq 0) { throw "Existing-action support '$file' contains no function definitions." }
        $files[$file] = (@($functions | ForEach-Object { $_.Extent.Text }) -join "`n")
    }
    return ($files | ConvertTo-Json -Compress)
}

function Initialize-MemLabsScopedHierarchyActionRun {
    param([Parameter(Mandatory)]$DeployConfig, [object[]]$Actions = @(),
        [Parameter(Mandatory)][guid]$RunId)

    if ($RunId -eq [guid]::Empty) { throw 'Scoped role actions require a nonempty phase RunId.' }
    foreach ($vm in @(Get-MemLabsRequestedDeploymentVMs -DeployConfig $DeployConfig)) {
        $vm.PSObject.Properties.Remove('phase8ScopedHierarchyAction')
    }
    foreach ($action in @($Actions | Where-Object { $_.Kind -eq 'SiteRoles' })) {
        $action | Add-Member -NotePropertyName RunId -NotePropertyValue $RunId.ToString() -Force
        foreach ($targetName in @($action.TargetVMNames)) {
            $targets = @(Get-MemLabsRequestedDeploymentVMs -DeployConfig $DeployConfig | Where-Object { $_.vmName -eq $targetName })
            if ($targets.Count -ne 1 -or (Test-MemLabsContextOnlyVM -VM $targets[0])) {
                throw "Cannot stamp a scoped action on unrequested context '$targetName'."
            }
            if ($targets[0].phase8ScopedHierarchyAction) { throw "Requested VM '$targetName' has conflicting scoped role-action owners." }
            $targets[0] | Add-Member -NotePropertyName phase8ScopedHierarchyAction -NotePropertyValue ([pscustomobject]@{
                    Kind = 'SiteRoles'; RunId = $RunId.ToString(); OwnerVMName = "$($action.OwnerVMName)"; TargetVMName = "$targetName"
                }) -Force
        }
    }
}

function Get-MemLabsScopedRoleRetryRunId {
    param([Parameter(Mandatory)]$DeployConfig, [Parameter(Mandatory)][string[]]$VMNames)

    $runIds = @(
        foreach ($vm in @(Get-MemLabsRequestedDeploymentVMs -DeployConfig $DeployConfig | Where-Object { $_.vmName -in $VMNames })) {
            if (-not $vm.PSObject.Properties['phase8ScopedHierarchyAction']) { continue }
            $marker = $vm.phase8ScopedHierarchyAction
            $id = [guid]::Empty
            $owners = @($DeployConfig.virtualMachines | Where-Object { $_.vmName -eq $marker.OwnerVMName })
            if ($marker.Kind -ne 'SiteRoles' -or $marker.TargetVMName -ne $vm.vmName -or
                -not [guid]::TryParse("$($marker.RunId)", [ref]$id) -or $id -eq [guid]::Empty -or
                $owners.Count -ne 1 -or -not (Test-MemLabsContextOnlyVM -VM $owners[0])) {
                throw "Requested retry '$($vm.vmName)' has an invalid outstanding scoped role-action identity."
            }
            $id.ToString()
        }
    ) | Select-Object -Unique
    if (@($runIds).Count -gt 1) { throw 'Requested retries belong to different scoped role-action runs; they cannot share a preparation token.' }
    if (@($runIds).Count -eq 1) { return @($runIds)[0] }
}

function Publish-MemLabsScopedHierarchyActionReceipt {
    param([Parameter(Mandatory)]$DeployConfig, [Parameter(Mandatory)]$Action,
        [Parameter(Mandatory)][ValidateSet('Completed', 'Failed')][string]$Status, [string]$Message)

    $runId = [guid]::Empty
    if (-not [guid]::TryParse("$($Action.RunId)", [ref]$runId) -or $runId -eq [guid]::Empty) { throw 'Scoped role-action receipt has no valid phase RunId.' }
    foreach ($targetName in @($Action.TargetVMNames)) {
        $targets = @(Get-MemLabsRequestedDeploymentVMs -DeployConfig $DeployConfig | Where-Object { $_.vmName -eq $targetName })
        if ($targets.Count -ne 1 -or (Test-MemLabsContextOnlyVM -VM $targets[0])) {
            throw "Scoped receipt cannot be published to unrequested context '$targetName'."
        }
        $domain = if ($targets[0].domain) { $targets[0].domain } else { $DeployConfig.vmOptions.domainName }
        $receipt = @{
            SchemaVersion = 1; Kind = 'SiteRoles'; RunId = "$($Action.RunId)"
            OwnerVMName = "$($Action.OwnerVMName)"; TargetVMName = "$targetName"; Status = $Status
            Message = "$Message"; UpdatedAtUtc = [DateTime]::UtcNow.ToString('o')
        }
        $deadline = [DateTime]::UtcNow.AddMinutes(10)
        do {
            $result = Invoke-VmCommand -VmName $targetName -VmDomainName $domain -AsJob -TimeoutSeconds 60 `
                -SessionMaxRetries 1 -RebootIfUnresponsive:$false -FailOnRemoteError -SuppressLog -ScriptBlock {
                param([string]$Json, [string]$StagingRoot = 'C:\staging\DSC')
                $ErrorActionPreference = 'Stop'
                $receipt = $Json | ConvertFrom-Json
                $id = [guid]::Empty
                if (-not [guid]::TryParse("$($receipt.RunId)", [ref]$id) -or
                    $receipt.TargetVMName -ine $env:COMPUTERNAME -or
                    $receipt.Status -notin @('Completed', 'Failed')) { throw 'Invalid scoped receipt target/identity.' }
                $staging = $StagingRoot
                $readyPath = Join-Path $staging 'RunGuid.txt'
                if (-not (Test-Path -LiteralPath $readyPath) -or
                    (Get-Content -LiteralPath $readyPath -Raw -ErrorAction Stop).Trim() -ne $receipt.RunId) {
                    return 'WAITING_FOR_CURRENT_TARGET_PREPARATION'
                }
                $folder = Join-Path $staging 'ScopedHierarchyActions'
                $null = New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop
                $path = Join-Path $folder "$($receipt.RunId).json"
                $temp = Join-Path $folder "$($receipt.RunId).$([guid]::NewGuid().ToString('N')).tmp"
                try {
                    $receipt | ConvertTo-Json -Compress | Set-Content -LiteralPath $temp -Encoding UTF8 -ErrorAction Stop
                    Move-Item -LiteralPath $temp -Destination $path -Force -ErrorAction Stop
                }
                finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction Stop } }
                'PUBLISHED'
            } -ArgumentList @($receipt | ConvertTo-Json -Compress)
            if (-not $result -or $result.ScriptBlockFailed) { throw "Cannot publish scoped role-action receipt to '$targetName': $($result.ErrorDetails)" }
            if ($result.ScriptBlockOutput -contains 'PUBLISHED') { break }
            if ($result.ScriptBlockOutput -notcontains 'WAITING_FOR_CURRENT_TARGET_PREPARATION') {
                throw "Scoped receipt producer returned an invalid result for requested VM '$targetName'."
            }
            if ($Status -eq 'Failed' -or [DateTime]::UtcNow -ge $deadline) {
                throw "Requested target '$targetName' did not reach current-run preparation before scoped receipt publication."
            }
            Write-Log "[Phase 8] ${targetName}: waiting for its own current-run preparation before publishing the scoped role-action receipt."
            Start-Sleep -Seconds 5
        } while ($true)
    }
}

function Invoke-MemLabsExistingHierarchyActions {
    param([Parameter(Mandatory)]$DeployConfig, [Parameter(Mandatory)][object[]]$Actions)

    $order = @{ SiteRoles = 10; Osd = 20; ClientPush = 30; BitLocker = 40 }
    foreach ($action in @($Actions | Sort-Object { $order[$_.Kind] })) {
        $requestedNames = @(Get-MemLabsRequestedDeploymentVMs -DeployConfig $DeployConfig | ForEach-Object { "$($_.vmName)" })
        if (@($action.TargetVMNames).Count -eq 0 -or
            @($action.TargetVMNames | Where-Object { -not $_ -or $_ -notin $requestedNames }).Count -gt 0) {
            throw "Scoped $($action.Kind) execution included an unrequested context target."
        }
        if ($action.Kind -eq 'SiteRoles' -and (-not $action.PSObject.Properties['RunId'] -or -not $action.RunId)) {
            throw 'Site-role actions require current-run target receipt identities before execution.'
        }
        if ($action.PSObject.Properties['HostPreflightText'] -and $action.HostPreflightText) {
            $null = & ([scriptblock]::Create($action.HostPreflightText)) $action.Payload
        }
        if ($action.Kind -eq 'ClientPush') {
            Invoke-MemLabsExistingClientPush -DeployConfig $DeployConfig -OnlyVMs @($action.OwnerVMName) -OnlyClients @($action.TargetVMNames)
            continue
        }
        $owner = @($DeployConfig.virtualMachines | Where-Object { $_.vmName -eq $action.OwnerVMName })
        if ($owner.Count -ne 1 -or -not (Test-MemLabsContextOnlyVM -VM $owner[0])) {
            throw "Existing action '$($action.Kind)' lost its unique context owner."
        }
        $live = Get-VM -Name $action.OwnerVMName -ErrorAction Stop
        if ("$($live.State)" -ne 'Running') {
            throw "Required existing owner '$($action.OwnerVMName)' is '$($live.State)'; it will not be started or repaired."
        }
        $domain = if ($owner[0].domain) { "$($owner[0].domain)" } else { "$($DeployConfig.vmOptions.domainName)" }
        $adminName = if ($owner[0].adminName) { "$($owner[0].adminName)" } else { "$($DeployConfig.vmOptions.adminName)" }
        $credential = [pscredential]::new(
            "$domain\$adminName", $Common.LocalAdmin.Password)
        Write-Log "[Deployment intent] $($action.OwnerVMName): $($action.Kind) only for $(@($action.TargetVMNames) -join ', '); no general hierarchy workflow."
        $arguments = @(
            "$($action.SiteCode)", ($action.Payload | ConvertTo-Json -Depth 40 -Compress),
            "$($action.HandlerText)", (Get-MemLabsExistingActionSupportSource),
            (Get-MemLabsExistingSiteConnectionScript).ToString(),
            ($DeployConfig | ConvertTo-Json -Depth 40 -Compress), "$($action.OwnerVMName)", "$($action.Kind)", $credential,
            (ConvertTo-Json -InputObject @($action.TargetVMNames) -Compress)
        )
        try {
        $result = Invoke-VmCommand -VmName $action.OwnerVMName -VmDomainName $domain -VmDomainAccount $adminName -RequireDomainIdentity -AsJob `
            -TimeoutSeconds $action.TimeoutSeconds -SessionMaxRetries 1 -RebootIfUnresponsive:$false `
            -FailOnRemoteError -ScriptBlock {
            param($ExpectedSiteCode, $PayloadJson, $HandlerText, $SupportSource, $ConnectionSource,
                $DeployJson, $OwnerName, $Kind, [pscredential]$DomainCredential, [string]$ExpectedTargetsJson)
            $ErrorActionPreference = 'Stop'
            $deployConfig = $DeployJson | ConvertFrom-Json
            $global:deployConfig = $deployConfig
            $ThisVM = @($deployConfig.virtualMachines | Where-Object { $_.vmName -eq $OwnerName })[0]
            $global:ThisVM = $ThisVM
            if (-not $ThisVM -or $ThisVM.siteCode -ne $ExpectedSiteCode) { throw 'Scoped action owner/site identity changed.' }
            $global:CurrentRole = $ThisVM.role
            $global:SiteCode = $ExpectedSiteCode
            $global:DomainFullName = if ($ThisVM.domain) { $ThisVM.domain } else { $deployConfig.vmOptions.domainName }
            $global:NetbiosDomainName = if ($ThisVM.domainNetBiosName) { $ThisVM.domainNetBiosName } else { $deployConfig.vmOptions.domainNetBiosName }
            $global:Admincreds = $DomainCredential
            $global:CMAdmin = $DomainCredential
            $options = if ($ThisVM.cmOptions) { $ThisVM.cmOptions } else { $deployConfig.cmOptions }
            $global:usePKI = $options.UsePKI
            $global:offlineSUP = $options.OfflineSUP
            $actionRoot = Join-Path $env:ProgramData ("MemLabs\Actions\" + [guid]::NewGuid().ToString('N'))
            $actionConfigPath = Join-Path $actionRoot 'deployConfig.json'
            $completed = $false
            try {
            $global:LogPath = $actionRoot
            $null = New-Item -ItemType Directory -Path $LogPath -ErrorAction Stop
            $acl = Get-Acl -LiteralPath $LogPath -ErrorAction Stop
            $acl.SetAccessRuleProtection($true, $false)
            foreach ($sidText in @('S-1-5-18', 'S-1-5-32-544')) {
                $sid = [Security.Principal.SecurityIdentifier]::new($sidText)
                $rule = [Security.AccessControl.FileSystemAccessRule]::new(
                    $sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
                $acl.AddAccessRule($rule)
            }
            Set-Acl -LiteralPath $LogPath -AclObject $acl -ErrorAction Stop
            $supportFiles = $SupportSource | ConvertFrom-Json
            foreach ($file in @('ProcessFunctions.ps1', 'ScriptFunctions.ps1')) {
                $sourcePath = Join-Path $LogPath $file
                [IO.File]::WriteAllText($sourcePath, "$($supportFiles.$file)", [Text.UTF8Encoding]::new($true))
                . $sourcePath
            }
            $global:StatusFile = Join-Path $LogPath 'Status.txt'
            $global:StatusLog = Join-Path $LogPath 'Action.log'
            $global:ConfigFilePath = $actionConfigPath
            $global:ConfigurationFile = Join-Path $LogPath 'ScriptWorkflow.json'
            $handlerPath = Join-Path $LogPath 'Action.ps1'
            [IO.File]::WriteAllText($handlerPath, "$HandlerText", [Text.UTF8Encoding]::new($true))
            $deployConfig.parameters | Add-Member -NotePropertyName ThisMachineName -NotePropertyValue $OwnerName -Force
            $deployConfig | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $ConfigFilePath -Encoding UTF8 -ErrorAction Stop
                . ([scriptblock]::Create($ConnectionSource)) $ExpectedSiteCode
                $failureSequence = [int]$global:MemLabsFailureSequence
                $output = @(& $handlerPath ($PayloadJson | ConvertFrom-Json))
                if ([int]$global:MemLabsFailureSequence -ne $failureSequence) {
                    throw "Scoped $Kind action reported failure: $global:MemLabsLastFailureStatus"
                }
                if ($output.Count -ne 1 -or $output[0].Status -isnot [string] -or
                    $output[0].Status -notin @('Completed', 'Submitted')) {
                    throw "Scoped $Kind action did not return one verified completion/submission receipt."
                }
                $expectedTargets = ConvertFrom-Json -InputObject $ExpectedTargetsJson
                $expectedTargets = @($expectedTargets)
                $actualTargets = @($output[0].TargetVMNames)
                if ($actualTargets.Count -ne $expectedTargets.Count -or
                    @($actualTargets | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count -gt 0 -or
                    (@($actualTargets | Sort-Object) -join ',') -ne (@($expectedTargets | Sort-Object) -join ',')) {
                    throw "Scoped $Kind receipt targets [$($actualTargets -join ', ')] ($($actualTargets.Count)) did not match requested targets [$($expectedTargets -join ', ')] ($($expectedTargets.Count))."
                }
                $completed = $true
                $output[0]
            }
            catch {
                throw "Scoped $Kind action is blocked on existing owner '$OwnerName': $($_.Exception.Message) Evidence: $actionRoot. No general recovery was attempted."
            }
            finally {
                foreach ($secretFile in @($actionConfigPath, (Join-Path $actionRoot 'cm_svc.txt'))) {
                    if (Test-Path -LiteralPath $secretFile) { Remove-Item -LiteralPath $secretFile -Force -ErrorAction Stop }
                }
                if ($completed) { Remove-Item -LiteralPath $actionRoot -Recurse -Force -ErrorAction Stop }
            }
        } -ArgumentList $arguments
        $receipts = @($result.ScriptBlockOutput | Where-Object { $_.Status -in @('Completed', 'Submitted') })
        if (-not $result -or $result.ScriptBlockFailed -or $receipts.Count -ne 1 -or
            (@($receipts[0].TargetVMNames | Sort-Object) -join ',') -ne (@($action.TargetVMNames | Sort-Object) -join ',')) {
            throw "Scoped $($action.Kind) action failed on '$($action.OwnerVMName)'; the existing hierarchy was not reconciled. $($result.ScriptBlockOutput) $($result.ErrorDetails)"
        }
        if ($action.Kind -eq 'SiteRoles' -and $action.PSObject.Properties['RunId']) {
            if ($receipts[0].Status -ne 'Completed') { throw 'A submitted site-role request has not proven its required native completion postcondition.' }
            Publish-MemLabsScopedHierarchyActionReceipt -DeployConfig $DeployConfig -Action $action -Status Completed
        }
        }
        catch {
            $actionFailure = $_
            if ($action.Kind -eq 'SiteRoles' -and $action.PSObject.Properties['RunId']) {
                try { Publish-MemLabsScopedHierarchyActionReceipt -DeployConfig $DeployConfig -Action $action -Status Failed -Message $actionFailure.Exception.Message }
                catch { Write-Log "[Phase 8] Scoped action failed and its requested-target failure receipt could not be published: $($_.Exception.Message)" -Warning }
            }
            throw $actionFailure
        }
    }
}
