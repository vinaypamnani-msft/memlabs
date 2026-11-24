function Get-MemLabsExistingBitLockerActions {
    param([Parameter(Mandatory)]$DeployConfig)

    $byOwner = @{}
    foreach ($vm in @(Get-MemLabsRequestedDeploymentVMs -DeployConfig $DeployConfig | Where-Object { $_.BitLocker -eq $true })) {
        $siteCode = if ($vm.pushClient -is [string] -and $vm.pushClient -notin @('true', 'false')) { "$($vm.pushClient)" } else { "$($vm.siteCode)" }
        $owner = Resolve-MemLabsDeploymentPrimary -DeployConfig $DeployConfig -SiteCode $siteCode
        if (-not (Test-MemLabsContextOnlyVM -VM $owner)) { continue }
        if (-not $byOwner.ContainsKey($owner.vmName)) {
            $byOwner[$owner.vmName] = @{ Owner = $owner; Targets = [Collections.Generic.List[string]]::new() }
        }
        $byOwner[$owner.vmName].Targets.Add("$($vm.vmName)")
    }
    foreach ($group in $byOwner.Values) {
        $targets = @($group.Targets | Select-Object -Unique)
        [pscustomobject]@{
            Kind = 'BitLocker'
            OwnerVMName = $group.Owner.vmName
            SiteCode = "$($group.Owner.siteCode)"
            TargetVMNames = $targets
            TimeoutSeconds = 180
            Payload = [pscustomobject]@{ SiteCode = "$($group.Owner.siteCode)"; TargetVMNames = $targets }
            Handler = {
                param($Payload)
                $namespace = "root\SMS\site_$($Payload.SiteCode)"
                $definitions = @(Get-WmiObject -Namespace $namespace -Class SMS_SCI_SiteDefinition `
                    -Filter "SiteCode='$($Payload.SiteCode)'" -ErrorAction Stop)
                if ($definitions.Count -ne 1) { throw 'Existing BitLocker site configuration cannot be read uniquely; it was not repaired.' }
                $definition = $definitions[0]
                if ($definition.PSObject.Methods['Get']) { $definition.Get() }
                $enabled = @($definition.Props | Where-Object { $_.PropertyName -eq 'EnableMBAMRecoveryService' })
                if ($enabled.Count -ne 1 -or $enabled[0].Value -ne 1) {
                    throw 'Existing BitLocker recovery service is not enabled. It will not be enabled or restarted as part of client enrollment.'
                }
                $collections = @(Get-CMDeviceCollection -Name 'MEMLABS-BitLocker Clients' -ErrorAction Stop)
                $policies = @(Get-CMBlmSetting -Name 'MEMLABS-BitLocker Policy' -ErrorAction Stop)
                if ($collections.Count -ne 1 -or -not $collections[0].CollectionID -or $policies.Count -ne 1) {
                    throw 'Existing BitLocker collection/policy is missing or ambiguous; baseline objects were left unchanged.'
                }
                $collectionId = "$($collections[0].CollectionID)"
                $deployments = @(Get-CMSettingDeployment -CMSetting $policies[0] -ErrorAction Stop |
                    Where-Object { $_.CollectionID -eq $collectionId })
                if ($deployments.Count -eq 0) { throw 'Existing BitLocker policy is not deployed to its collection; no deployment repair was attempted.' }
                $existingRules = @(Get-CMDeviceCollectionQueryMembershipRule -CollectionId $collectionId -ErrorAction Stop)
                $missing = @(
                    foreach ($name in @($Payload.TargetVMNames)) {
                        if ([string]::IsNullOrWhiteSpace($name) -or $name -notmatch '^[A-Za-z0-9][A-Za-z0-9-]*$') {
                            throw "Invalid requested BitLocker computer name '$name'."
                        }
                        $ruleName = "BLM-$name"
                        $query = "SELECT * FROM SMS_R_System WHERE Name = '$name'"
                        $rules = @($existingRules | Where-Object { $_.RuleName -eq $ruleName })
                        if ($rules.Count -gt 1 -or ($rules.Count -eq 1 -and $rules[0].QueryExpression -ne $query)) {
                            throw "Existing BitLocker membership rule '$ruleName' conflicts with this request; it was not rewritten."
                        }
                        if ($rules.Count -eq 0) { [pscustomobject]@{ Name = $ruleName; Query = $query } }
                    }
                )
                foreach ($rule in $missing) {
                    Add-CMDeviceCollectionQueryMembershipRule -CollectionId $collectionId -RuleName $rule.Name `
                        -QueryExpression $rule.Query -ErrorAction Stop | Out-Null
                }
                if ($missing.Count -gt 0) { Invoke-CMCollectionUpdate -CollectionId $collectionId -ErrorAction Stop | Out-Null }
                [pscustomobject]@{ Status = 'Submitted'; TargetVMNames = @($Payload.TargetVMNames) }
            }
        }
    }
}
