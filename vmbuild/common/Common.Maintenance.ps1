
function Start-Maintenance {

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "If present, maintenance runs only for machines in DeployConfig")]
        [object]$DeployConfig
    )

    $applyNewOnly = $false
    if ($DeployConfig) {
        Write-log "Start-Maintenance called with DeployConfig"
        $allVMs = $DeployConfig.virtualMachines | Where-Object { -not $_.hidden }
        $vmsNeedingMaintenance = $DeployConfig.virtualMachines | Where-Object { -not $_.hidden } | Sort-Object vmName
        $applyNewOnly = $true
    }
    else {
        Write-log -verbose "Start-Maintenance called without DeployConfig"
        $allVMs = Get-List -Type VM | Where-Object { $_.vmBuild -eq $true -and $_.inProgress -ne $true }
        $vmsNeedingMaintenance = $allVMs | Where-Object { -not $_.memLabsVersion -or $_.memLabsVersion -lt $Common.LatestHotfixVersion } | Sort-Object vmName
    }

    Write-Log -Verbose "Latest Hotfix Version: $($Common.LatestHotfixVersion)"
    $countWorked = $countFailed = $countSkipped = 0
    # Filter in-progress. Also exclude offline StandaloneRootCA VMs - they are
    # intentionally powered off after issuing sub-CA certs and should not be
    # offered for maintenance or auto-started.
    $vmsNeedingMaintenance = $vmsNeedingMaintenance | Where-Object {
        $_.inProgress -ne $true -and
        -not ($_.Role -in @("OSDClient", "Linux", "AADClient")) -and
        -not ($_.Role -eq "StandaloneRootCA" -and $_.State -ne "Running")
    }
    $newVmsNeedingMaintenance = @()
    foreach ($vm in $vmsNeedingMaintenance) {
        Write-Log -Verbose "VM Name: $($vm.vmName) Version: $($vm.memLabsVersion)"
        $mutexName = $vm.vmName

        try {
            $Mutex = [System.Threading.Mutex]::OpenExisting($MutexName)
        }
        catch {
            Write-Log -Verbose "Mutex $mutexName does not exist.. VM not in use."
            #Mutex does not exist.
            $newVmsNeedingMaintenance = $newVmsNeedingMaintenance + $vm
            continue
        }
        if ($Mutex) {
            Write-Log -Verbose "Mutex $mutexName exists.. VM in use."
            $countSkipped++
            try {
                [void]$Mutex.ReleaseMutex()
            }
            catch {}
        }
    }
    $vmCount = ($newVmsNeedingMaintenance | Measure-Object).Count
    $countNotNeeded = $allVMs.Count - $vmCount

    $text = "Performing maintenance"
    $maintenanceDoNotStart = $false
    Write-Log $text -Activity
    $stoppedCount = 0
    $stoppedVms = @()
    if ($applyNewOnly -eq $false) {
        if ($vmCount -gt 0) {
            $response = Read-YesOrNoWithTimeout -Prompt "$($newVmsNeedingMaintenance.Count) VM(s) [$($newVmsNeedingMaintenance.vmName -join ",")] need memlabs maintenance. Run now? (y/N)" -HideHelp -Default "n" -timeout 15
            if ($response -eq "n") {
                return
            }
            foreach ($vm in $newVmsNeedingMaintenance) {
                if ($vm.State -ne "Running") {
                    $stoppedCount++
                    $stoppedVms += $vm.vmName                
                }
            }
            if ($stoppedCount -gt 0) {
                $response = Read-YesOrNoWithTimeout -Prompt "$stoppedCount VMs stopped. Start [$($stoppedVms-join ",")] for Maintenance (y/N)" -HideHelp -Default "n" -timeout 15
                if ($response -eq "y") {
                    Write-Log "$vmCount VMs need maintenance. VMs will be started (if stopped) and shut down post-maintenance."
                }
                else {
                    Write-Log "$vmCount VMs need maintenance. VMs will NOT be started (if stopped)."
                    $maintenanceDoNotStart = $true
                }
            }
        }
        else {
            Write-Log "No maintenance required." -Success
            return
        }
    }

    foreach ($vm in $newVmsNeedingMaintenance) {
        if ($maintenanceDoNotStart) {
            if ($vm.State -ne "Running") {
                $newVmsNeedingMaintenance = $newVmsNeedingMaintenance | Where-Object { $_.vmName -ne $vm.vmName }
                $countSkipped++
                continue
            }
        }
    }

    $start = Start-NormalJobs -machines $newVmsNeedingMaintenance -ScriptBlock $global:Phase10Job -Phase "Maintenance" -argument1 '' -argument2 $false

    $result = Wait-Phase -Phase "Maintenance" -Jobs $start.Jobs -AdditionalData $start.AdditionalData

    #foreach ($vm in $newVmsNeedingMaintenance | Where-Object { $_.role -eq "DC" }) {
    #    $i++
    #    Write-Progress2 -Id $progressId -Activity $text -Status "Performing maintenance on VM $i/$vmCount`: $($vm.vmName)" -PercentComplete (($i / $vmCount) * 100)
    #    $worked = Start-VMMaintenance -VMName $vm.vmName -ApplyNewOnly:$applyNewOnly
    #    if ($worked) { $countWorked++ } else {
    #        $failedDomains += $vm.domain
    #        $countFailed++
    #    }
    #}

    $countWorked = $result.Success
    $countFailed = $result.Failed
          

    Write-Host
    Write-Log "Finished maintenance. Success: $countWorked; Failures: $countFailed; Skipped: $countSkipped; Already up-to-date: $countNotNeeded" -SubActivity
    Start-Sleep -seconds 3
    clear-host

    if ($global:MaintenanceActivity) {
        Write-Progress2 -Activity $global:MaintenanceActivity -Completed
    }
}

function Show-FailedDomains {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Failed Domains")]
        [object] $failedDomains
    )

    $failedDCs = Get-List -Type VM | Where-Object { $_.role -eq "DC" -and $_.domain -in $failedDomains }
    $dcList = ($failedDCs | Select-Object vmName, domain, @{Name = "accountsToUpdate"; Expression = { @("vmbuildadmin", $_.adminName, "cm_svc") } }, @{ Name = "desiredPassword"; Expression = { $($Common.LocalAdmin.GetNetworkCredential().Password) } } | Out-String).Trim()
    $dcList = $dcList -split "`r`n"

    Write-Log "Displaying the failed domains message for ($($failedDomains -join ','))." -LogOnly

    $longest = 130
    $longestMinus1 = $longest - 1

    Write-Host
    Write-Host2 "  #".PadRight($longest, "#") -ForegroundColor Yellow
    Write-Host2 "  # DC Maintenance failed for below domains. This may be because the passwords for the required accounts (listed below) expired. #" -ForegroundColor Yellow
    Write-Host2 ("  #".PadRight($longestMinus1, " ") + "#") -ForeGroundColor Yellow
    foreach ($line in $dcList) {
        $newLine = $line -replace '\x1b\[[0-9;]*m'
        Write-Host2 -ForegroundColor Yellow "  #" -NoNewLine
        #subtract the 3 chars displayed above
        $Len = $longestMinus1 - 3
        Write-Host2 " $newLine".PadRight($len, " ").Replace($newLine, $line) -ForegroundColor Turquoise -NoNewLine
        Write-Host2 -ForeGroundColor Yellow "#"
    }
    Write-Host2 ("  #".PadRight($longestMinus1, " ") + "#") -ForegroundColor Yellow
    Write-Host2 ("  # Please perform manual remediation steps listed below to keep VMBuild functional.".PadRight($longestMinus1, " ") + "#") -ForegroundColor Yellow
    Write-Host2 ("  #".PadRight($longestMinus1, " ") + "#") -ForegroundColor Yellow
    Write-Host2 ("  # 1. Logon to the affected DC's using Hyper-V console.".PadRight($longestMinus1, " ") + "#") -ForegroundColor Yellow
    Write-Host2 ("  # 2. Launch 'AD Users and Computers', and reset the account for the above listed accounts to the desiredPassword.".PadRight($longestMinus1, " ") + "#") -ForegroundColor Yellow
    Write-Host2 ("  # 3. Run 'VMBuild.cmd' again.".PadRight($longestMinus1, " ") + "#") -ForegroundColor Yellow
    Write-Host2 ("  #".PadRight($longestMinus1, " ") + "#") -ForegroundColor Yellow
    Write-Host2 ("  # If the password hasn't expired/changed, re-run VMBuild.cmd in case there was a transient issue.".PadRight($longestMinus1, " ") + "#") -ForegroundColor Yellow
    Write-Host2 ("  # If the issue persists, please report it.".PadRight($longestMinus1, " ") + "#") -ForegroundColor Yellow
    Write-Host2 ("  #".PadRight($longestMinus1, " ") + "#") -ForegroundColor Yellow
    Write-Host2 "  #".PadRight($longest, "#") -ForegroundColor Yellow

}

function Start-VMMaintenance {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "VMName")]
        [object] $VMName,
        [Parameter(Mandatory = $false, HelpMessage = "Apply fixes applicable to new")]
        [switch] $ApplyNewOnly
    )

    Write-Log "Starting maintenance for VM: $VMName"

    $vmNoteObject = Get-VMNote -VMName $VMName

    if (-not $vmNoteObject) {
        Write-Log "$vmName`: VM Notes property could not be read. Skipping." -Warning
        return $false
    }

    # Offline Root CAs are intentionally powered off; skip if not running
    if ($vmNoteObject.role -eq "StandaloneRootCA") {
        $vmState = (Get-VM2 -Name $VMName -ErrorAction SilentlyContinue).State
        if ($vmState -ne "Running") {
            Write-Log "$VMName`: StandaloneRootCA is offline (expected). Skipping maintenance." -Success
            return $true
        }
    }

    $global:MaintenanceActivity = $VMName
    $latestFixVersion = $Common.LatestHotfixVersion
    $inProgress = if ($vmNoteObject.inProgress) { $true } else { $false }
    $vmVersion = $vmNoteObject.memLabsVersion

    # This should never happen, since parent filters these out. Leaving just-in-case.
    if ($inProgress) {
        Write-Log "$vmName`: VM Deployment State is in-progress. Skipping." -Warning
        return $false
    }

    # This should never happen, unless Get-List provides outdated version, so check again with current VMNote object
    if ($vmVersion -ge $latestFixVersion -and -not $ApplyNewOnly.IsPresent) {
        Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "VM Version ($vmVersion) is up-to-date."
        return $true
    }

    if ($ApplyNewOnly.IsPresent) {
        Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status  "Newly deployed VM is NOT up-to-date. Required Hotfix Version is $latestFixVersion. Performing maintenance..."
    }
    else {
        Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status  "VM (version $vmVersion) is NOT up-to-date. Required Hotfix Version is $latestFixVersion. Performing maintenance..."
    }

    if ($ApplyNewOnly.IsPresent) {
        $vmFixes = Get-VMFixes -newVM $true -VMName $VMName | Where-Object { $_.AppliesToNew -eq $true }
    }
    else {
        $vmFixes = Get-VMFixes -newVM $false -VMName $VMName | Where-Object { $_.AppliesToExisting -eq $true }
    }

    $worked = Start-VMFixes -VMName $VMName -VMFixes $vmFixes -ApplyNewOnly:$ApplyNewOnly

    if ($worked) {
        Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status  "VM maintenance completed successfully."
        Set-VMNote -vmName $VMName -vmVersion ([string]$latestFixVersion) -forceVersionUpdate
        $logoffusers = {
            try {
                query user 2>&1 | Select-Object -skip 1 | ForEach-Object {
                    logoff ($_ -split "\s+")[-6]
                }
            }
            catch {}
        }
        try {
            if ($ApplyNewOnly.IsPresent) {
                Invoke-VmCommand -VmName $VMName -VmDomainName $vmNoteObject.domain -ScriptBlock $logoffusers
            }
        }
        catch {}
    }
    else {
        Write-Log "$VMName`: VM maintenance failed. Review VMBuild.log." -Failure
        Show-Notification -ToastText "$VMName`: VM maintenance failed. Review VMBuild.log." -ToastTag $VMName
    }

    return $worked
}

function Start-VMFixes {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "VMName")]
        [string] $VMName,
        [Parameter(Mandatory = $true, HelpMessage = "VMFixes")]
        [object] $VMFixes,
        [Parameter(Mandatory = $false, HelpMessage = "SkipVMShutdown")]
        [switch] $SkipVMShutdown,
        [Parameter(Mandatory = $false, HelpMessage = "Apply fixes applicable to new")]
        [switch] $ApplyNewOnly
    )

    Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Applying fixes to the virtual machine."

    $success = $false
    $toStop = @()

    $rootPath = Split-Path $PSScriptRoot -Parent

    $vmNote = Get-VMNote -VMName $vmName
    $vmDomain = $vmNote.domain

    if (-not $vmDomain) {
        Write-log "No domain found in VMNote for $vmName.. assuming unmanaged. Return true" -LogOnly
        return $true
    }

    $HashArguments = @{
        VmName       = $vmName
        VMDomainName = $vmDomain
        DisplayName  = "Testing for Memlabs files"
        ScriptBlock  = { Test-Path "C:\Staging" }
    }

    $result = Invoke-VmCommand @HashArguments -ShowVMSessionError -CommandReturnsBool
    if ($result.ScriptBlockOutput -eq $false) {
        Write-Log "C:\Staging not found in vm $VMName.  Machine may no longer be managed by MemLabs.  Returning success." -Success -OutputStream
        return $true
    }

    $copyResults = Copy-ItemSafe -VmName $vmName -VMDomainName $vmDomain -Path "$rootPath\DSC" -Destination "C:\staging" -Recurse -Container -Force

    # Determine if we can use the batched fast-path (no fixes have DependentVMs)
    $sortedFixes = $VMFixes | Sort-Object FixVersion
    $hasDependentVMs = $sortedFixes | Where-Object { $_.DependentVMs -and $_.DependentVMs.Count -gt 0 -and $_.AppliesToThisVM }

    if (-not $hasDependentVMs) {
        # Fast path: batch all fixes into a single remote call per session type
        $batchResult = Start-VMFixesBatched -VMName $VMName -VMDomain $vmDomain -VMFixes $sortedFixes -ApplyNewOnly:$ApplyNewOnly
        $success = $batchResult.Success
        $toStop = $batchResult.VMsToStop
        $fixesAppliedCount = $batchResult.AppliedCount
        $fixesApplicableCount = $batchResult.ApplicableCount
    }
    else {
        # Slow path: sequential per-fix execution (needed when fixes have dependent VMs)
        $fixesAppliedCount = 0
        $fixesApplicableCount = 0
        foreach ($vmFix in $sortedFixes) {
            if ($vmFix.AppliesToThisVM) { $fixesApplicableCount++ }
            $status = Start-VMFix -vmName $VMName -vmFix $vmFix -ApplyNewOnly:$ApplyNewOnly
            $toStop += $status.VMsToStop
            $success = $status.Success
            if ($status.Applied) { $fixesAppliedCount++ }
            if (-not $success) {
                $resetVersion = [int]($vmFix.FixVersion) - 1
                Set-VMNote -vmName $VMName -vmVersion ([string]$resetVersion) -forceVersionUpdate
                break
            }
        }
    }

    # If deploying a new VM and fixes were applicable but none actually ran
    # their script block, something is wrong — do not stamp the version.
    # (If zero were applicable, e.g. OSDClient/Linux/AADClient, that's expected.)
    if ($ApplyNewOnly.IsPresent -and $fixesApplicableCount -gt 0 -and $fixesAppliedCount -eq 0 -and $success) {
        Write-Log "$VMName`: WARNING - $fixesApplicableCount maintenance fixes were applicable but none were applied. Version will NOT be stamped." -Warning
        $success = $false
    }

    if ($toStop.Count -ne 0 -and -not $SkipVMShutdown.IsPresent) {
        foreach ($vm in $toStop) {
            if ([string]::IsNullOrWhiteSpace($vm)) {
                continue
            }
            $vmNote = Get-VMNote -VMName $vm
            if ($vmNote.role -ne "DC") {
                Write-Progress2 -Activity $global:MaintenanceActivity -Status  "Shutting down VM "
                Stop-Vm2 -Name $vm -retryCount 5 -retrySeconds 3
            }
        }
    }

    return $success
}

function Start-VMFixesBatched {
    <#
    .SYNOPSIS
        Executes all applicable maintenance fixes in a single remote call per session type.
        Eliminates per-fix Invoke-VmCommand round-trip overhead (~2-4s each).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $VMName,
        [Parameter(Mandatory = $true)]
        [string] $VMDomain,
        [Parameter(Mandatory = $true)]
        [object[]] $VMFixes,
        [Parameter(Mandatory = $false)]
        [switch] $ApplyNewOnly
    )

    $return = [PSCustomObject]@{
        Success         = $false
        AppliedCount    = 0
        ApplicableCount = 0
        VMsToStop       = @()
    }

    $vmNote = Get-VMNote -VMName $VMName

    # Stamp non-applicable fixes immediately (host-side, no remote call needed)
    $applicableFixes = @()
    foreach ($vmFix in $VMFixes) {
        if ($vmNote.memLabsVersion -ge $vmFix.FixVersion -and -not $ApplyNewOnly.IsPresent) {
            # Already applied
            continue
        }
        if (-not $vmFix.AppliesToThisVM) {
            Set-VMNote -VMName $VMName -vmVersion $vmFix.FixVersion
            continue
        }
        $return.ApplicableCount++
        $applicableFixes += $vmFix
    }

    if ($applicableFixes.Count -eq 0) {
        $return.Success = $true
        return $return
    }

    # Start the VM
    Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Starting $VMName for batched maintenance."
    $status = Start-VMIfNotRunning -VMName $VMName -VMDomain $VMDomain -WaitForConnect -Quiet
    if ($status.StartedVM) { $return.VMsToStop += $VMName }
    if ($status.StartFailed) { return $return }

    # Copy all InjectFiles upfront in one session
    $allInjectFiles = $applicableFixes | Where-Object { $_.InjectFiles } | ForEach-Object { $_.InjectFiles } | Select-Object -Unique
    $allInjectTools = $applicableFixes | Where-Object { $_.InjectTools } | ForEach-Object { $_.InjectTools } | Select-Object -Unique
    if ($allInjectFiles -or $allInjectTools) {
        try {
            $ps = Get-VmSession -VmName $VMName -VmDomainName $VMDomain
            foreach ($file in $allInjectFiles) {
                $sourcePath = Join-Path $Common.StagingInjectPath "staging\$file"
                $targetPathInVM = "C:\staging\$file"
                Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Copying $file to the VM..."
                Copy-Item -ToSession $ps -Path $sourcePath -Destination $targetPathInVM -Force -ErrorAction Stop
            }
            foreach ($toolFolder in $allInjectTools) {
                $sourcePath = Join-Path $Common.StagingInjectPath "tools\$toolFolder"
                if (Test-Path $sourcePath) {
                    $targetPathInVM = "C:\tools\$toolFolder"
                    Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Copying tool '$toolFolder' to the VM..."
                    Copy-Item -ToSession $ps -Path $sourcePath -Destination $targetPathInVM -Recurse -Force -ErrorAction Stop
                }
            }
        }
        catch {
            Write-Log "$VMName`: Failed to copy InjectFiles/InjectTools for batched maintenance." -Warning
            return $return
        }
    }

    # Group fixes by RunAsAccount (null/default vs specific account)
    $groups = @{}
    foreach ($fix in $applicableFixes) {
        $key = if ($fix.RunAsAccount) { $fix.RunAsAccount } else { "__default__" }
        if (-not $groups.ContainsKey($key)) { $groups[$key] = @() }
        $groups[$key] += $fix
    }

    # Build and execute a batched scriptblock for each session group
    # Process groups in version order of their first fix
    $sortedKeys = $groups.Keys | Sort-Object { ($groups[$_] | Select-Object -First 1).FixVersion }

    foreach ($key in $sortedKeys) {
        $groupFixes = $groups[$key]

        # Build fix definitions array for transport into the VM.
        # We wrap each fix body in the standard transcript + structured-return wrapper.
        $fixDefs = @()
        foreach ($fix in $groupFixes) {
            $wrapped = New-VMFixScriptBlock -FixName $fix.FixName -Body $fix.ScriptBlock
            $def = @{
                Name   = $fix.FixName
                Script = $wrapped.ToString()
            }
            if ($fix.ArgumentList) {
                $def.Args = $fix.ArgumentList
            }
            $fixDefs += $def
        }

        $fixDefsJson = $fixDefs | ConvertTo-Json -Depth 4 -Compress
        if ($fixDefs.Count -eq 1) {
            # ConvertTo-Json doesn't wrap single items in array
            $fixDefsJson = "[$fixDefsJson]"
        }

        # The batch runner: executes all wrapped fixes sequentially inside the VM,
        # collects their structured results, and returns them as JSON. Fail-fast on
        # the first failure (subsequent fixes assume prior ones succeeded).
        $batchRunner = {
            param($json)
            $fixDefs = $json | ConvertFrom-Json
            $results = @()
            foreach ($def in $fixDefs) {
                $sb = [scriptblock]::Create($def.Script)
                $r = $null
                try {
                    if ($def.Args) {
                        $fixArgs = @($def.Args)
                        $r = & $sb @fixArgs
                    }
                    else {
                        $r = & $sb
                    }
                }
                catch {
                    # The wrapper should normally catch its own exceptions; this
                    # catches only catastrophic failures (e.g. wrapper compilation).
                    $r = [pscustomobject]@{
                        FixName       = $def.Name
                        Success       = $false
                        Message       = $null
                        Errors        = @()
                        ExceptionInfo = "$($_.Exception.Message)`n$($_.ScriptStackTrace)"
                        ComputerName  = $env:COMPUTERNAME
                        DurationSec   = 0
                        IsStructured  = $true
                    }
                }
                # Normalize whatever came back into a structured record
                if ($r -is [pscustomobject] -and ($r.PSObject.Properties.Name -contains 'IsStructured')) {
                    $results += $r
                }
                else {
                    $results += [pscustomobject]@{
                        FixName       = $def.Name
                        Success       = [bool]$r
                        Message       = $null
                        Errors        = @()
                        ExceptionInfo = $null
                        ComputerName  = $env:COMPUTERNAME
                        DurationSec   = 0
                        IsStructured  = $true
                    }
                }
                if (-not $results[-1].Success) { break }
            }
            return ($results | ConvertTo-Json -Depth 4 -Compress)
        }

        # Get session for this group
        $sessionArgs = @{ VmName = $VMName; VmDomainName = $VMDomain; ShowVMSessionError = $true }
        if ($key -ne "__default__") {
            $sessionArgs.VmDomainAccount = $key
        }
        $ps = Get-VmSession @sessionArgs
        if (-not $ps) {
            # Fallback: try default session
            $ps = Get-VmSession -VmName $VMName -VmDomainName $VMDomain -ShowVMSessionError
        }
        if (-not $ps) {
            Write-Log "$VMName`: Failed to get session for batched fixes (account: $key)." -Warning
            return $return
        }

        Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Executing $($groupFixes.Count) fixes in batch (account: $(if ($key -eq '__default__') {'default'} else {$key}))..."

        try {
            $rawOutput = Invoke-Command -Session $ps -ScriptBlock $batchRunner -ArgumentList $fixDefsJson -ErrorVariable batchErr -ErrorAction SilentlyContinue
        }
        catch {
            Write-Log "$VMName`: Batched fix execution failed with exception: $_" -Warning
            return $return
        }

        if ($batchErr.Count -ne 0) {
            Write-Log "$VMName`: Batched fix execution had errors: $($batchErr[0].ToString().Trim())" -Warning
        }

        # Parse results
        if (-not $rawOutput) {
            Write-Log "$VMName`: Batched fix returned no output." -Warning
            return $return
        }

        try {
            $results = $rawOutput | ConvertFrom-Json
            # Ensure it's an array
            if ($results -isnot [array]) { $results = @($results) }
        }
        catch {
            Write-Log "$VMName`: Failed to parse batched fix results: $_" -Warning
            return $return
        }

        $accountForTranscript = if ($key -eq "__default__") { $null } else { $key }

        foreach ($r in $results) {
            $matchingFix = $groupFixes | Where-Object { $_.FixName -eq $r.Name -or $_.FixName -eq $r.FixName } | Select-Object -First 1
            $fixDisplayName = if ($matchingFix) { $matchingFix.FixName } else { $r.FixName }

            # Log structured fields
            if ($r.PSObject.Properties.Name -contains 'Message' -and $r.Message) {
                Write-Log "$VMName`: [$fixDisplayName] $($r.Message)"
            }
            if ($r.PSObject.Properties.Name -contains 'Errors' -and $r.Errors -and @($r.Errors).Count -gt 0) {
                foreach ($e in @($r.Errors)) { Write-Log "$VMName`: [$fixDisplayName] ERROR: $e" -Warning }
            }
            if ($r.PSObject.Properties.Name -contains 'ExceptionInfo' -and $r.ExceptionInfo) {
                Write-Log "$VMName`: [$fixDisplayName] EXCEPTION on VM: $($r.ExceptionInfo)" -Warning
            }
            if ($r.PSObject.Properties.Name -contains 'DurationSec') {
                Write-Log -LogOnly "$VMName`: [$fixDisplayName] Success=$($r.Success) DurationSec=$($r.DurationSec)"
            }

            # Always pull transcript (LogOnly) so failures + slow fixes are diagnosable
            Get-VMFixTranscript -VMName $VMName -VMDomain $VMDomain -FixName $fixDisplayName -VMDomainAccount $accountForTranscript

            if ($r.Success) {
                Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Fix '$fixDisplayName' ($($matchingFix.FixVersion)) applied."
                Set-VMNote -vmName $VMName -vmVersion $matchingFix.FixVersion
                $return.AppliedCount++
            }
            else {
                Write-Log "$VMName`: Fix '$fixDisplayName' ($($matchingFix.FixVersion)) failed in batch." -Warning
                $resetVersion = [int]($matchingFix.FixVersion) - 1
                Set-VMNote -vmName $VMName -vmVersion ([string]$resetVersion) -forceVersionUpdate
                return $return
            }
        }

        # If fewer results than fixes in group, the batch broke early (shouldn't happen if fail-fast returned)
        if ($results.Count -lt $groupFixes.Count) {
            $failedFix = $groupFixes[$results.Count]
            Write-Log "$VMName`: Batch stopped before fix '$($failedFix.FixName)'. Possible crash in scriptblock." -Warning
            # Pull transcript for the fix that we suspect crashed mid-execution
            Get-VMFixTranscript -VMName $VMName -VMDomain $VMDomain -FixName $failedFix.FixName -VMDomainAccount $accountForTranscript
            $resetVersion = [int]($failedFix.FixVersion) - 1
            Set-VMNote -vmName $VMName -vmVersion ([string]$resetVersion) -forceVersionUpdate
            return $return
        }
    }

    $return.Success = $true
    return $return
}

function Start-VMFix {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "vmName")]
        [string] $vmName,
        [Parameter(Mandatory = $true, HelpMessage = "vmFix")]
        [object] $vmFix,
        [Parameter(Mandatory = $false, HelpMessage = "Apply fixes applicable to new")]
        [switch] $ApplyNewOnly
    )

    $return = [PSCustomObject]@{
        Success   = $false
        Applied   = $false
        VMsToStop = @()
    }


    # Get current VM note to ensure we don't have outdated version
    $vmNote = Get-VMNote -VMName $vmName
    $vmDomain = $vmNote.domain


    # Check applicability
    $fixName = $vmFix.FixName
    $fixVersion = $vmFix.FixVersion
    write-log -LogOnly "Applying Fix $fixName $fixVersion to $vmName"
    if ($vmNote.memLabsVersion -ge $fixVersion -and -not $ApplyNewOnly.IsPresent) {
        Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Fix '$fixName' ($fixVersion) has been applied already."
        $return.Success = $true
        return $return
    }

    if (-not $vmFix.AppliesToThisVM) {
        Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Fix '$fixName' ($fixVersion) is not applicable. Updating version to '$fixVersion'"
        Set-VMNote -VMName $vmName -vmVersion $fixVersion
        $return.Success = $true
        return $return
    }

    Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Fix '$fixName' ($fixVersion) is applicable. Applying fix now."

    # Start dependent VM's
    if ($vmFix.DependentVMs) {
        $dependentVMs = $vmFix.DependentVMs
        Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Fix '$fixName' ($fixVersion) requires '$($dependentVMs -join ',')' to be running."
        foreach ($vm in $dependentVMs) {
            if ([string]::IsNullOrWhiteSpace($vm)) { continue }
            $note = Get-VMNote -VMName $vm
            $status = Start-VMIfNotRunning -VMName $vm -VMDomain $note.domain -WaitForConnect -Quiet
            if ($status.StartedVM) {
                $return.VMsToStop += $vm
            }

            if ($status.StartFailed) {
                return $return
            }
        }
    }
    Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Fix '$fixName' Starting $VMName."
    # Start VM to apply fix
    $status = Start-VMIfNotRunning -VMName $VMName -VMDomain $vmDomain -WaitForConnect -Quiet
    if ($status.StartedVM) {
        $return.VMsToStop += $VMName
    }

    if ($status.StartFailed) {
        return $return
    }
    
    # Apply Fix
    $HashArguments = @{
        VmName       = $VMName
        VMDomainName = $vmDomain
        DisplayName  = $fixName
        ScriptBlock  = $vmFix.ScriptBlock
    }

    if ($vmFix.ArgumentList) {
        $HashArguments.Add("ArgumentList", $vmFix.ArgumentList)
    }

    if ($vmFix.RunAsAccount) {
        $HashArguments.Add("VmDomainAccount", $vmFix.RunAsAccount)
    }

    start-sleep -Milliseconds 200
    Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Fix '$fixName' Connecting to $VMName"
    if ($vmFix.InjectFiles -or $vmFix.InjectTools) {
        try {
            $ps = Get-VmSession -VmName $VMName -VmDomainName $vmDomain
            foreach ($file in $vmFix.InjectFiles) {
                $sourcePath = Join-Path $Common.StagingInjectPath "staging\$file"
                $targetPathInVM = "C:\staging\$file"
                Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Copying $file to the VM [$targetPathInVM]..."
                Copy-Item -ToSession $ps -Path $sourcePath -Destination $targetPathInVM -Force -ErrorAction Stop
            }
            foreach ($toolFolder in $vmFix.InjectTools) {
                $sourcePath = Join-Path $Common.StagingInjectPath "tools\$toolFolder"
                if (Test-Path $sourcePath) {
                    $targetPathInVM = "C:\tools\$toolFolder"
                    Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Copying tool '$toolFolder' to the VM..."
                    Copy-Item -ToSession $ps -Path $sourcePath -Destination $targetPathInVM -Recurse -Force -ErrorAction Stop
                }
            }
        }
        catch {
            Write-Log "$VMName`: Failed to copy files for fix '$fixName' ($fixVersion)." -Warning
            $return.Success = $false
            return $return
        }
    }

    start-sleep -Milliseconds 200
    Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Fix '$fixName' Starting ScriptBlock on $VMName"

    # Wrap the fix body so we get a structured return + transcript on the VM
    $HashArguments.ScriptBlock = New-VMFixScriptBlock -FixName $fixName -Body $vmFix.ScriptBlock

    # Drop -CommandReturnsBool: output is now a structured PSCustomObject.
    $result = Invoke-VmCommand @HashArguments -ShowVMSessionError
    $rawOut = $result.ScriptBlockOutput
    $isStructured = ($null -ne $rawOut) -and ($rawOut -is [pscustomobject]) -and `
                    ($rawOut.PSObject.Properties.Name -contains 'IsStructured')

    $fixSucceeded = $false
    if ($result.ScriptBlockFailed) {
        # Transport/session failure - body never ran (or failed catastrophically).
        $fixSucceeded = $false
    }
    elseif ($isStructured) {
        $fixSucceeded = [bool]$rawOut.Success
        if ($rawOut.Message) {
            Write-Log "$VMName`: [$fixName] $($rawOut.Message)"
        }
        if ($rawOut.Errors -and $rawOut.Errors.Count -gt 0) {
            foreach ($e in $rawOut.Errors) {
                Write-Log "$VMName`: [$fixName] ERROR: $e" -Warning
            }
        }
        if ($rawOut.ExceptionInfo) {
            Write-Log "$VMName`: [$fixName] EXCEPTION on VM: $($rawOut.ExceptionInfo)" -Warning
        }
        Write-Log -LogOnly "$VMName`: [$fixName] Success=$($rawOut.Success) DurationSec=$($rawOut.DurationSec)"
    }
    else {
        # Legacy bool return (back-compat)
        $fixSucceeded = ($rawOut -eq $true)
    }

    # Always pull the on-VM transcript and dump it to the host log (LogOnly).
    Get-VMFixTranscript -VMName $VMName -VMDomain $vmDomain -FixName $fixName -VMDomainAccount $vmFix.RunAsAccount

    if (-not $fixSucceeded) {
        Write-Log "$VMName`: Fix '$fixName' ($fixVersion) failed to be applied." -Warning
        Write-Log "ScriptBlockFailed: $($result.ScriptBlockFailed) Output: $(if ($isStructured) { 'Success=' + $rawOut.Success } else { $rawOut })"
        Write-Log -LogOnly "ScriptBlock: $($vmFix.ScriptBlock)"
        $return.Success = $false
    }
    else {
        Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Fix '$fixName' ($fixVersion) applied. Updating version to $fixVersion."
        Set-VMNote -vmName $VMName -vmVersion $fixVersion
        $return.Success = $true
        $return.Applied = $true
    }

    return $return
}

function Start-VMIfNotRunning {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "VM Name")]
        [string] $VMName,
        [Parameter(Mandatory = $true, HelpMessage = "VM Domain")]
        [string] $VMDomain,
        [Parameter(Mandatory = $false, HelpMessage = "Wait for VM to be connectable")]
        [switch] $WaitForConnect,
        [Parameter(Mandatory = $false, HelpMessage = "Quiet - No logging when VM is already running")]
        [switch] $Quiet
    )

    $return = [PSCustomObject]@{
        StartedVM     = $false
        StartFailed   = $false
        ConnectFailed = $false
    }


    $vm = Get-VM2 -Name $VMName -ErrorAction SilentlyContinue

    Write-Log -verbose "Starting $vmName if not running"

    if (-not $vm) {
        Write-Log "$VMName`: Failed to get VM from Hyper-V. Error: $_" -Warning
        $return.StartFailed = $true
        $return.ConnectFailed = $true
        return $return
    }

    if ($vm.State -ne "Running") {
        Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Starting VM for maintenance and waiting for it to be ready to connect."
        $started = Start-VM2 -Name $VMName -Passthru
        if ($started) {
            $return.StartedVM = $true
            if ($WaitForConnect.IsPresent) {
                Write-Log -verbose "Waiting to connect to $vmName"
                $connected = Wait-ForVM -VmName $VMname -PathToVerify "C:\Users" -VmDomainName $VMDomain -TimeoutMinutes 2 -Quiet
                if (-not $connected) {
                    Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Could not connect to the VM after waiting for 2 minutes."
                    $return.ConnectFailed = $true
                }
            }
        }
        else {
            $return.StartFailed = $true
            $return.ConnectFailed = $true
        }
    }
    else {
        if (-not $Quiet.IsPresent) { Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "VM is already running." }
    }
    Write-Log -verbose "Starting $vmName Completed. $return"
    return $return
}

function New-VMFixScriptBlock {
    <#
    .SYNOPSIS
        Wraps a fix body scriptblock with a standard transcript + structured-return
        wrapper that runs on the VM.
    .DESCRIPTION
        The wrapper:
          - Starts Start-Transcript to C:\staging\Fix\<FixName>.txt
          - Exposes a Write-FixLog helper to the body (Info/Warning/Failure/Success)
          - Runs the body in try/catch; captures exceptions
          - Returns a PSCustomObject:
              FixName, Success, Message, Errors[], ExceptionInfo, ComputerName,
              StartedAt, DurationSec, IsStructured = $true
        Body return value handling (back-compat):
          - $null              -> Success = $true
          - [bool]             -> Success = value
          - PSCustomObject     -> If it has .Success, copy Success/Message/Errors
          - other              -> Cast last item to bool
        The body's own param(...) block is preserved; ArgumentList from
        Invoke-VmCommand is forwarded into the body via $args.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$FixName,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )

    $bodyText = $Body.ToString()
    # Escape any backticks/$ in the FixName for safe embedding in a here-string.
    $safeName = $FixName -replace "'", "''"

    $wrapperText = @"
# Auto-generated wrapper for fix '$safeName'
`$__FixName = '$safeName'
if (-not (Test-Path 'C:\staging\Fix')) {
    New-Item -Path 'C:\staging\Fix' -ItemType Directory -Force | Out-Null
}
`$__transcriptPath = "C:\staging\Fix\`$__FixName.txt"
`$__result = [pscustomobject]@{
    FixName       = `$__FixName
    Success       = `$false
    Message       = `$null
    Errors        = @()
    ExceptionInfo = `$null
    ComputerName  = `$env:COMPUTERNAME
    StartedAt     = (Get-Date).ToString('o')
    DurationSec   = 0
    IsStructured  = `$true
}
`$__sw = [System.Diagnostics.Stopwatch]::StartNew()
try { Start-Transcript -Path `$__transcriptPath -Force -ErrorAction Stop | Out-Null } catch { }
try {
    Write-Host "[`$__FixName] Starting on `$env:COMPUTERNAME at `$(Get-Date -Format 'u')"
    function Write-FixLog {
        [CmdletBinding()]
        param(
            [Parameter(ValueFromPipeline = `$true, Position = 0)][string]`$Message,
            [ValidateSet('Info','Warning','Failure','Success')][string]`$Level = 'Info'
        )
        process {
            `$ts = (Get-Date).ToString('HH:mm:ss.fff')
            Write-Host "[`$ts][`$Level] `$Message"
        }
    }
    # --- BEGIN FIX BODY ---
    `$__bodyOut = & {
$bodyText
    } @args
    # --- END FIX BODY ---
    if (`$null -eq `$__bodyOut) {
        `$__result.Success = `$true
    }
    elseif (`$__bodyOut -is [pscustomobject] -and (`$__bodyOut.PSObject.Properties.Name -contains 'Success')) {
        `$__result.Success = [bool]`$__bodyOut.Success
        if (`$__bodyOut.PSObject.Properties.Name -contains 'Message') { `$__result.Message = `$__bodyOut.Message }
        if (`$__bodyOut.PSObject.Properties.Name -contains 'Errors')  { `$__result.Errors  = @(`$__bodyOut.Errors) }
    }
    else {
        # Take last emitted value (back-compat with fixes that return `$true/`$false at the end)
        `$__last = @(`$__bodyOut) | Select-Object -Last 1
        `$__result.Success = [bool]`$__last
    }
}
catch {
    `$__result.Success = `$false
    `$__result.ExceptionInfo = "`$(`$_.Exception.Message)``n`$(`$_.ScriptStackTrace)"
    Write-Host "[`$__FixName] EXCEPTION: `$(`$_.Exception.Message)"
    Write-Host "[`$__FixName] `$(`$_.ScriptStackTrace)"
}
finally {
    `$__sw.Stop()
    `$__result.DurationSec = [math]::Round(`$__sw.Elapsed.TotalSeconds, 2)
    try { Stop-Transcript | Out-Null } catch { }
}
`$__result
"@

    return [scriptblock]::Create($wrapperText)
}

function Get-VMFixTranscript {
    <#
    .SYNOPSIS
        Pulls the C:\staging\Fix\<FixName>.txt transcript from a VM and writes
        each line to the host log with a TR/FixName prefix.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$VMName,
        [Parameter(Mandatory = $true)][string]$VMDomain,
        [Parameter(Mandatory = $true)][string]$FixName,
        [string]$VMDomainAccount
    )
    $sb = {
        param($name)
        $p = "C:\staging\Fix\$name.txt"
        if (Test-Path $p) { Get-Content -Path $p -ErrorAction SilentlyContinue }
    }
    $args = @{
        VmName       = $VMName
        VMDomainName = $VMDomain
        ScriptBlock  = $sb
        ArgumentList = @($FixName)
        DisplayName  = "Pull transcript: $FixName"
        SuppressLog  = $true
    }
    if ($VMDomainAccount) { $args.VmDomainAccount = $VMDomainAccount }
    try {
        $r = Invoke-VmCommand @args
        if ($r -and $r.ScriptBlockOutput) {
            Write-Log "$VMName`: ===== Transcript [$FixName] BEGIN =====" -LogOnly
            foreach ($line in @($r.ScriptBlockOutput)) {
                if ($null -ne $line -and "$line" -ne "") {
                    Write-Log -LogOnly "$VMName`: [$FixName] $line"
                }
            }
            Write-Log "$VMName`: ===== Transcript [$FixName] END =====" -LogOnly
        }
    }
    catch {
        Write-Log "$VMName`: Failed to pull transcript for [$FixName]: $_" -LogOnly -Warning
    }
}

function Get-VMFixes {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "VMName", ParameterSetName = "Real")]
        [object] $VMName,
        [Parameter(Mandatory = $true, HelpMessage = "VMName", ParameterSetName = "Dummy")]
        [switch] $ReturnDummyList,
        [bool] $NewVM = $true
    )

    if ($ReturnDummyList.IsPresent) {
        $vmNote = $null
    }
    else {
        $vmNote = Get-VMNote -VMName $VMName
        $dc = Get-List -Type VM | Where-Object { $_.role -eq "DC" -and $_.domain -eq $vmNote.domain }
    }

    $fixesToPerform = @()
    ### Domain account password expiration

    #region Fix-DomainAccounts

    $Fix_DomainAccount = {
        param ($accountName)
        $accountsToUpdate = @("vmbuildadmin", "administrator", "cm_svc", $accountName) | Select-Object -Unique
        $accountsUpdated = 0
        $errs = @()
        foreach ($account in $accountsToUpdate) {
            $i = 0
            do {
                $i++
                Set-ADUser -Identity $account -PasswordNeverExpires $true -CannotChangePassword $true -ErrorVariable AccountError -ErrorAction SilentlyContinue | out-null
                if ($AccountError.Count -ne 0) {
                    Write-FixLog "Set-ADUser '$account' attempt $i failed: $($AccountError[0])" -Level Warning
                    Start-Sleep -Seconds (5 * $i)
                }
            }
            until ($i -ge 5 -or $AccountError.Count -eq 0)

            if ($AccountError.Count -eq 0) {
                $accountsUpdated++
                Write-FixLog "Updated '$account'" -Level Success
            }
            else {
                $errs += "Failed to update '$account' after $i attempts: $($AccountError[0])"
            }
        }
        [pscustomobject]@{
            Success = ($accountsUpdated -eq $accountsToUpdate.Count)
            Message = "Updated $accountsUpdated of $($accountsToUpdate.Count) accounts"
            Errors  = $errs
        }
    }

    $fixesToPerform += [PSCustomObject]@{
        FixName           = "Fix-DomainAccounts"
        FixVersion        = "211125.1"
        AppliesToNew      = $false
        AppliesToExisting = $true
        AppliesToRoles    = @("DC")
        NotAppliesToRoles = @("OSDClient", "Linux", "AADClient")
        DependentVMs      = @()
        ScriptBlock       = $Fix_DomainAccount
        ArgumentList      = @($vmNote.adminName)
    }
    #endregion
    ### Local account password expiration

    #region Fix-Prereq
    $Fix_Prereq = {
        $SiteCode = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code'
        if (-not $SiteCode) {
            Write-host "No sitecode in HKLM:\SOFTWARE\Microsoft\SMS\Identification"
            return $true
        }
        $version = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS' -Name 'Full Version'
        if (-not $version) {
            Write-host "No Version found in HKLM:\SOFTWARE\Microsoft\SMS\Full Version"
            return $false
        }

        if ([System.Version]$version -lt [System.Version]"5.0.9128") {
            Write-Host "2309 or older.. Should not force EHTTP"
            return $true
        }
        
        $NameSpace = "ROOT\SMS\site_$SiteCode"
        $component = gwmi -ns $NameSpace -Query "SELECT * FROM SMS_SCI_Component WHERE FileType=2 AND ItemName='SMS_SITE_COMPONENT_MANAGER|SMS Site Server' AND ItemType='Component' AND SiteCode='$SiteCode'"
        $props = $component.Props
        $index = [Array]::IndexOf($props.PropertyName, 'IISSSLState')
        $value = $props[$index].Value    
        $enabled = ($value -band 1024) -eq 1024 -or ($value -eq 63) -or ($value -eq 1472) -or ($value -eq 1504)
        if (-not $enabled) {
            Write-Host  "IISSSLSTATE $value is not correct.. Updated for EHTTP"
            $props[$index].Value = 1024
            $component.Props = $props
            $component.Put()
            return $true
        }
        else {
            write-host "IISSSLSTATE of $value looks good.. You should not be failing at prereq check"
            return $true
        }
    }

    $fixesToPerform += [PSCustomObject]@{
        FixName           = "Fix-PreReq"
        FixVersion        = "250116.0"
        AppliesToNew      = $false
        AppliesToExisting = $true
        AppliesToRoles    = @("CAS")
        NotAppliesToRoles = @()
        DependentVMs      = @()
        ScriptBlock       = $Fix_Prereq 
    }
    #endregion


    #region Fix-Upgrade-Console
    $Fix_UpgradeConsole = {
        & C:\staging\DSC\phases\Upgrade-Console.ps1
        return $true
    }

    $fixesToPerform += [PSCustomObject]@{
        FixName           = "Fix-Upgrade-Console"
        FixVersion        = "250107.0"
        AppliesToNew      = $true
        AppliesToExisting = $false
        AppliesToRoles    = @("Primary", "CAS")
        NotAppliesToRoles = @()
        DependentVMs      = @()
        ScriptBlock       = $Fix_UpgradeConsole
    }
    #endregion


    #region Fix-LocalAccount
    $Fix_LocalAccount = {
        Set-LocalUser -Name "vmbuildadmin" -PasswordNeverExpires $true -ErrorAction SilentlyContinue -ErrorVariable AccountError
        if ($AccountError.Count -eq 0) {
            return $true
        }
        else {
            return $false
        }
    }

    $fixesToPerform += [PSCustomObject]@{
        FixName           = "Fix-LocalAccount"
        FixVersion        = "211125.2"
        AppliesToNew      = $true
        AppliesToExisting = $true
        AppliesToRoles    = @()
        NotAppliesToRoles = @("DC", "OSDClient", "Linux", "AADClient")
        DependentVMs      = @()
        ScriptBlock       = $Fix_LocalAccount
    }
    #endregion
    # Default user profile

    #region Fix-DefaultUserProfile
    $Fix_DefaultProfile = {
        $path1 = "C:\Users\Default\AppData\Local\Microsoft\Windows\WebCache"
        $path2 = "C:\Users\Default\AppData\Local\Microsoft\Windows\INetCache"
        $path3 = "C:\Users\Default\AppData\Local\Microsoft\Windows\WebCacheLock.dat"
        if (Test-Path $path1) { Remove-Item -Path $path1 -Force -Recurse -ProgressAction SilentlyContinue | Out-Null }
        if (Test-Path $path2) { Remove-Item -Path $path2 -Force -Recurse -ProgressAction SilentlyContinue | Out-Null }
        if (Test-Path $path3) { Remove-Item -Path $path3 -Force -ProgressAction SilentlyContinue | Out-Null }
        return $true
    }

    $fixesToPerform += [PSCustomObject]@{
        FixName           = "Fix-DefaultUserProfile"
        FixVersion        = "211126"
        AppliesToNew      = $true
        AppliesToExisting = $true
        AppliesToRoles    = @()
        NotAppliesToRoles = @("OSDClient", "Linux", "AADClient")
        DependentVMs      = @()
        ScriptBlock       = $Fix_DefaultProfile
    }
    #endregion

    #region Fix-CMFullAdmin
    # Full Admin in CM

    $Fix_CMFullAdmin = {
        $SiteCode = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code' -ErrorVariable ErrVar -ErrorAction SilentlyContinue
        if ($ErrVar.Count -ne 0 -or [string]::IsNullOrWhiteSpace($SiteCode)) {
            return [pscustomobject]@{ Success = $true; Message = 'No site code; CM not installed or uninstalled - skipping' }
        }

        # Use DNS domain (USERDNSDOMAIN) instead of bare USERDOMAIN; SMS Provider needs FQDN.
        $dnsDomain = $env:USERDNSDOMAIN
        if ([string]::IsNullOrWhiteSpace($dnsDomain)) {
            return [pscustomobject]@{ Success = $false; Message = 'USERDNSDOMAIN is empty; cannot build SMS Provider FQDN' }
        }
        $ProviderMachineName = "$env:COMPUTERNAME.$dnsDomain"
        Write-FixLog "SiteCode=$SiteCode Provider=$ProviderMachineName"

        # Get CM module path
        $key = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry32)
        $subKey = $key.OpenSubKey("SOFTWARE\Microsoft\ConfigMgr10\Setup")
        if (-not $subKey) {
            return [pscustomobject]@{ Success = $true; Message = 'CM admin console not installed - skipping' }
        }
        $uiInstallPath = $subKey.GetValue("UI Installation Directory")
        $modulePath = $uiInstallPath + "bin\ConfigurationManager.psd1"
        $initParams = @{}

        $userName = "vmbuildadmin"
        $userDomain = $env:USERDOMAIN
        $domainUserName = "$userDomain\$userName"
        $errs = @()

        $i = 0
        do {
            $i++
            if ($null -eq (Get-Module ConfigurationManager)) {
                Import-Module $modulePath -ErrorAction SilentlyContinue | out-null
            }
            New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName @initParams -ErrorAction SilentlyContinue | out-null
            $waits = 0
            while ($null -eq (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
                $waits++
                if ($waits -gt 6) {
                    $errs += "Could not create CMSite PSDrive '$SiteCode' against '$ProviderMachineName' after 60s"
                    return [pscustomobject]@{ Success = $false; Message = 'CMSite PSDrive never came online'; Errors = $errs }
                }
                Start-Sleep -Seconds 10
                New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName @initParams -ErrorAction SilentlyContinue | out-null
            }
            Set-Location "$($SiteCode):\" @initParams | out-null

            $exists = Get-CMAdministrativeUser -RoleName "Full Administrator" -ErrorAction SilentlyContinue |
                      Where-Object { $_.LogonName -like "*$userName*" }
            if ($exists) { break }

            Write-FixLog "Attempt $i`: Adding $domainUserName as Full Administrator"
            $newOut = New-CMAdministrativeUser -Name $domainUserName -RoleName "Full Administrator" `
                -SecurityScopeName "All", "All Systems", "All Users and User Groups" `
                -ErrorAction Continue -ErrorVariable NewErr 2>&1
            if ($newOut) { Write-FixLog ($newOut | Out-String).Trim() }
            if ($NewErr) {
                $msg = "New-CMAdministrativeUser attempt $i errors: $($NewErr -join '; ')"
                Write-FixLog $msg -Level Warning
                $errs += $msg
            }
            Start-Sleep -Seconds 15
            $exists = Get-CMAdministrativeUser -RoleName "Full Administrator" -ErrorAction SilentlyContinue |
                      Where-Object { $_.LogonName -like "*$userName*" }
        }
        until ($exists -or $i -gt 5)

        if ($exists) {
            [pscustomobject]@{ Success = $true; Message = "Full Administrator '$domainUserName' is present (verified after $i attempt(s))" }
        }
        else {
            [pscustomobject]@{ Success = $false; Message = "Failed to verify '$domainUserName' as Full Administrator after $i attempts"; Errors = $errs }
        }
    }

    $fixesToPerform += [PSCustomObject]@{
        FixName           = "Fix-CMFullAdmin"
        FixVersion        = "211127"
        AppliesToNew      = $false
        AppliesToExisting = $true
        AppliesToRoles    = @("CASorStandalonePrimary")
        NotAppliesToRoles = @("OSDClient", "Linux", "AADClient")
        DependentVMs      = @($dc.vmName, $vmNote.remoteSQLVM)
        ScriptBlock       = $Fix_CMFullAdmin
    }
    #endregion

    #region Fix-DisableIEESC
    # Disable IE Enhanced Security for all users via Scheduled task
    $Fix_DisableIEESC = {

        $os = Get-CimInstance -Class Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os) {
            if ($os.Producttype -eq 1) {
                return $true # workstation OS, fix not applicable
            }
        }
        else {
            return $false # failed to determine OS type, fail
        }

        $taskName = "Disable-IEESC"
        $filePath = "$env:systemdrive\staging\Disable-IEESC.ps1"

        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false | Out-Null
        }

        # Action
        $taskCommand = "cmd"
        $taskArgs = "/c start /min C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -WindowStyle Hidden -NonInteractive -Executionpolicy unrestricted -file $filePath"
        $action = New-ScheduledTaskAction -Execute $taskCommand -Argument $taskArgs

        # Trigger
        $trigger = New-ScheduledTaskTrigger -AtLogOn

        # Principal
        $principal = New-ScheduledTaskPrincipal -GroupId Users -RunLevel Highest

        # Task
        $definition = New-ScheduledTask -Action $action -Principal $principal -Trigger $trigger -Description "Disable IE Enhanced Security"

        Register-ScheduledTask -TaskName $taskName -InputObject $definition | Out-Null
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

        if ($null -ne $task) {
            return $true
        }
        else {
            return $false
        }
    }

    $fixesToPerform += [PSCustomObject]@{
        FixName           = "Fix-DisableIEESC"
        FixVersion        = "220422"
        AppliesToNew      = $true
        AppliesToExisting = $true
        AppliesToRoles    = @()
        NotAppliesToRoles = @("OSDClient", "Linux", "AADClient")
        DependentVMs      = @()
        ScriptBlock       = $Fix_DisableIEESC
        RunAsAccount      = $vmNote.adminName
        InjectFiles       = @("Disable-IEESC.ps1") # must exist in filesToInject\staging dir
    }

    #endregion

    #region Fix-CleanupSQL

    $Fix_CleanupSQL = {

        $os = Get-CimInstance -Class Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os) {
            if ($os.Producttype -eq 1) {
                return $true # workstation OS, fix not applicable
            }
        }
        else {
            return $false # failed to determine OS type, fail
        }

        $taskName = "MemLabs Cleanup SQL"
        $filePath = "$env:systemdrive\staging\Cleanup-SQL.ps1"

        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false | Out-Null
        }

        # Action
        $taskCommand = "cmd"
        $taskArgs = "/c start /min C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -WindowStyle Hidden -NonInteractive -Executionpolicy unrestricted -file $filePath"
        $action = New-ScheduledTaskAction -Execute $taskCommand -Argument $taskArgs

        # Trigger
        $trigger = New-ScheduledTaskTrigger -Daily -At 3am

        # Principal
        $principal = New-ScheduledTaskPrincipal -UserId "System"

        # Task
        $definition = New-ScheduledTask -Action $action -Principal $principal -Trigger $trigger -Description "Cleanup SQL"

        Register-ScheduledTask -TaskName $taskName -InputObject $definition | Out-Null
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

        if ($null -ne $task) {
            return $true
        }
        else {
            return $false
        }
    }

    $fixesToPerform += [PSCustomObject]@{
        FixName           = "Fix-CleanupSQL"
        FixVersion        = "241124"
        AppliesToNew      = $true
        AppliesToExisting = $true
        AppliesToRoles    = @()
        NotAppliesToRoles = @("OSDClient", "Linux", "AADClient")
        DependentVMs      = @()
        ScriptBlock       = $Fix_CleanupSQL
        RunAsAccount      = $vmNote.adminName
        InjectFiles       = @("Cleanup-SQL.ps1") # must exist in filesToInject\staging dir
    }

    #endregion

    #region Fix-EnableLogMachine

    $Fix_EnableLogMachine = {

        $taskName = "EnableLogMachine"
        $filePath = "$env:systemdrive\staging\Enable-LogMachine.ps1"

        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false | Out-Null
        }

        # Action
        $taskCommand = "cmd"
        $taskArgs = "/c start /min C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -WindowStyle Hidden -NonInteractive -Executionpolicy unrestricted -file $filePath"
        $action = New-ScheduledTaskAction -Execute $taskCommand -Argument $taskArgs

        # Trigger
        $trigger = New-ScheduledTaskTrigger -AtLogOn

        # Principal
        $principal = New-ScheduledTaskPrincipal -GroupId Users -RunLevel Highest

        # Task
        $definition = New-ScheduledTask -Action $action -Principal $principal -Trigger $trigger -Description "Enable Log Machine"

        Register-ScheduledTask -TaskName $taskName -InputObject $definition | Out-Null
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

        if ($null -ne $task) {
            return $true
        }
        else {
            return $false
        }
    }
    $fixesToPerform += [PSCustomObject]@{
        FixName           = "Fix-EnableLogMachine"
        FixVersion        = "250522"
        AppliesToNew      = $true 
        AppliesToExisting = $true
        AppliesToRoles    = @()
        NotAppliesToRoles = @("OSDClient", "Linux", "AADClient")
        DependentVMs      = @()
        ScriptBlock       = $Fix_EnableLogMachine
        RunAsAccount      = $vmNote.adminName
        InjectFiles       = @("Enable-LogMachine.ps1") # must exist in filesToInject\staging dir
        InjectTools       = @("LogMachine")            # ensures C:\tools\LogMachine exists on the VM
    }

    #endregion

    #region Fix-AccountExpiry

    $Fix_AccountExpiry = {

        $RegistryPath = 'HKLM:\\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters'
        $Name = 'DisablePasswordChange'
        $Value = '1'
        New-ItemProperty -Path $RegistryPath -Name $Name -Value $Value -PropertyType DWORD -Force | Out-Null
        return $true
    }

    $fixesToPerform += [PSCustomObject]@{
        FixName           = "Fix-AccountExpiry"
        FixVersion        = "230922"
        AppliesToNew      = $true
        AppliesToExisting = $true
        AppliesToRoles    = @()
        NotAppliesToRoles = @("DC", "OSDClient", "Linux", "AADClient")
        DependentVMs      = @()
        ScriptBlock       = $Fix_AccountExpiry

    }
    #endregion

    #region Fix_LocalAdminAccount
    $Fix_LocalAdminAccount = {
        param ($password)
        $p = ConvertTo-SecureString $password -AsPlainText -Force
        Set-LocalUser -Password $p "Administrator"
        Enable-LocalUser "Administrator"
        return $true
    }

    $fixesToPerform += [PSCustomObject]@{
        FixName           = "Fix_LocalAdminAccount"
        FixVersion        = "240710"
        AppliesToNew      = $true
        AppliesToExisting = $true
        AppliesToRoles    = @()
        NotAppliesToRoles = @("DC", "OSDClient", "Linux", "AADClient")
        DependentVMs      = @()
        ScriptBlock       = $Fix_LocalAdminAccount
        ArgumentList      = @($Common.LocalAdmin.GetNetworkCredential().Password)
    }
    #endregion

    #region Fix_ActivateWindows
    $Fix_ActivateWindows = {

        $atkms = "azkms.core.windows.net:1688"
        $winp = "W269N-WFGWX-YVC9B-4J6C9-T83GX"
        $wine = "NPPR9-FWDCX-D2C8J-H872K-2YT43"
        $cosname = (Get-CimInstance -Class Win32_OperatingSystem).Name
        
        if ($cosname -like "*Pro*") {
            $key = $winp
        }
        if ($cosname -like "*Enterprise*") {
            $key = $wine
        }
        
        if ($key) {
            cscript //NoLogo C:\Windows\system32\slmgr.vbs /skms $atkms > $null    
            Start-Sleep -Seconds 5        
            cscript //NoLogo C:\Windows\system32\slmgr.vbs /ipk $key > $null
            Start-Sleep -Seconds 5
            cscript //NoLogo C:\Windows\system32\slmgr.vbs /ato > $null
        }
        return $true
    }
        
    $fixesToPerform += [PSCustomObject]@{
        FixName           = "Fix_ActivateWindows"
        FixVersion        = "240713"
        AppliesToNew      = $true
        AppliesToExisting = $true
        AppliesToRoles    = @('DomainMember', 'WorkgroupMember', "InternetClient")
        NotAppliesToRoles = @()
        DependentVMs      = @()
        ScriptBlock       = $Fix_ActivateWindows
        RunAsAccount      = $vmNote.adminName
    }
    #endregion

    $Fix_RunSQL = {
        $SqlFilePath = "$env:systemdrive\staging\SQLFix-Compat.sql"
        if (-not (Test-Path $SqlFilePath)) {
            return [pscustomobject]@{ Success = $true; Message = 'No SQLFix-Compat.sql present - skipping' }
        }
        $regPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL"
        if (-not (Test-Path $regPath)) {
            return [pscustomobject]@{ Success = $true; Message = 'No SQL instances installed - skipping' }
        }
        $instances = (Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue).PSObject.Properties |
            Where-Object { $_.MemberType -eq 'NoteProperty' -and $_.Name -notin 'PSPath','PSParentPath','PSChildName','PSDrive','PSProvider' } |
            Select-Object -ExpandProperty Name
        if (-not $instances) {
            return [pscustomobject]@{ Success = $true; Message = 'No SQL instances found in registry - skipping' }
        }

        $ran = 0; $errs = @()
        foreach ($instance in $instances) {
            $sqlInstanceName = if ($instance -eq 'MSSQLSERVER') { '.' } else { ".\$instance" }
            Write-FixLog "Running SQLFix-Compat.sql against $sqlInstanceName"
            try {
                sqlcmd -S $sqlInstanceName -i $SqlFilePath -C 1>$null 2>$null
                $ran++
            }
            catch {
                $errs += "sqlcmd failed on ${sqlInstanceName}: $($_.Exception.Message)"
                Write-FixLog $errs[-1] -Level Failure
            }
        }
        [pscustomobject]@{
            Success = ($errs.Count -eq 0)
            Message = "Ran against $ran of $($instances.Count) instance(s)"
            Errors  = $errs
        }
    }

    $fixesToPerform += [PSCustomObject]@{
        FixName           = "Fix-RunSQL"
        FixVersion        = "260117"
        AppliesToNew      = $true 
        AppliesToExisting = $true
        AppliesToRoles    = @()
        NotAppliesToRoles = @("OSDClient", "Linux", "AADClient", "WorkgroupMember", "InternetClient", "DC", "BDC")
        DependentVMs      = @()
        ScriptBlock       = $Fix_RunSQL
        RunAsAccount      = $vmNote.adminName
        InjectFiles       = @("SQLFix-Compat.sql") # must exist in filesToInject\staging dir
    }

    #region Fix-ConfigureSSMS

    $Fix_ConfigureSSMS = {

        $taskName = "ConfigureSSMS"
        $filePath = "$env:systemdrive\staging\Configure-SSMS.ps1"

        # Only apply if SSMS is installed
        $ssmsInstalled = (Test-Path "C:\Program Files (x86)\Microsoft SQL Server Management Studio 18\Common7\IDE\ssms.exe") -or
                         (Test-Path "C:\Program Files (x86)\Microsoft SQL Server Management Studio 19\Common7\IDE\ssms.exe") -or
                         (Test-Path "C:\Program Files (x86)\Microsoft SQL Server Management Studio 20\Common7\IDE\ssms.exe")
        if (-not $ssmsInstalled) { return $true }

        # Run the script immediately (Phase 10 runs as admin, so %APPDATA% is correct)
        if (Test-Path $filePath) {
            try {
                & $filePath
            }
            catch {
                Write-Host "Configure-SSMS.ps1 threw an error: $_"
            }
        }

        # Register logon task so future logons pick up newly added SQL servers
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false | Out-Null
        }

        $taskCommand = "cmd"
        $taskArgs = "/c start /min C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -WindowStyle Hidden -NonInteractive -Executionpolicy unrestricted -file $filePath"
        $action = New-ScheduledTaskAction -Execute $taskCommand -Argument $taskArgs
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $principal = New-ScheduledTaskPrincipal -GroupId Users -RunLevel Highest
        $definition = New-ScheduledTask -Action $action -Principal $principal -Trigger $trigger -Description "Configure SSMS Registered Servers"

        Register-ScheduledTask -TaskName $taskName -InputObject $definition | Out-Null
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

        if ($null -ne $task) {
            return $true
        }
        else {
            return $false
        }
    }

    $fixesToPerform += [PSCustomObject]@{
        FixName           = "Fix-ConfigureSSMS"
        FixVersion        = "260522"
        AppliesToNew      = $true
        AppliesToExisting = $true
        AppliesToRoles    = @()
        NotAppliesToRoles = @("OSDClient", "Linux", "AADClient", "WorkgroupMember", "InternetClient", "DC", "BDC")
        DependentVMs      = @()
        ScriptBlock       = $Fix_ConfigureSSMS
        RunAsAccount      = $vmNote.adminName
        InjectFiles       = @("Configure-SSMS.ps1") # must exist in filesToInject\staging dir
    }

    #endregion


    # ========================
    # Determine applicability
    # ========================
    foreach ($vmFix in $fixesToPerform) {
        $applicable = $false
        $applicableRoles = $vmFix.AppliesToRoles
        if (-not $applicableRoles) {
            # Empty AppliesToRoles means "all roles". Use AllRoles list if available,
            # otherwise treat as universally applicable (covers InJob where
            # Set-SupportedOptions is skipped).
            $applicableRoles = $Common.Supported.AllRoles
        }
        if ($vmFix.NotAppliesToRoles -and $vmNote.role -in $vmFix.NotAppliesToRoles) {
            $applicable = $false
        }
        elseif (-not $applicableRoles -or $vmNote.role -in $applicableRoles) {
            $applicable = $true
        }
        else {
            $topLevelSite = $vmNote.role -eq "CAS" -or ($vmNote.role -eq "Primary" -and (-not $vmNote.parentSiteCode))
            if ($applicableRoles -contains "CASorStandalonePrimary" -and $topLevelSite) {
                $applicable = $true
            }
        }

        if (-not $newVM) {
            if ($vmNote.memLabsVersion -ge $vmFix.FixVersion) {
                $applicable = $false
            }
        }

        $vmfix | Add-Member -MemberType NoteProperty -Name AppliesToThisVM -Value $applicable -force

        # Filter out null's'
        $vmFix.DependentVMs = $vmFix.DependentVMs | Where-Object { $_ -and $_.Trim() }
    }

    return $fixesToPerform
}

function Start-CompactDisksUI {
    <#
    .SYNOPSIS
        Launches the WPF VHD-compaction worker as a detached process.

    .DESCRIPTION
        Spawns Compact-Disks.ps1 in a separate hidden PowerShell process. The
        worker shows a WPF progress window and runs Optimize-VHD in parallel
        for every VHD owned by the given VMs. The worker dot-sources
        Common.ps1 itself to pick up $Common.LocalAdmin for in-guest cleanup,
        so no credential plumbing is needed here. Returns immediately so the
        caller (genconfig) stays interactive.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string[]] $VMNames,

        [ValidateSet('Quick', 'Full', 'Retrim', 'Prezeroed')]
        [string] $Mode = 'Full',

        [ValidateRange(1, 16)]
        [int] $MaxConcurrentJobs = 8,

        [string] $DomainLabel
    )

    $scriptPath = Join-Path $PSScriptRoot '..\Compact-Disks.ps1'
    if (-not (Test-Path $scriptPath)) {
        Write-RedX "Compact-Disks.ps1 not found at $scriptPath"
        return
    }
    $scriptPath = (Resolve-Path $scriptPath).Path

    $vmListQuoted = ($VMNames | ForEach-Object { "'{0}'" -f ($_ -replace "'", "''") }) -join ','
    # NOTE: -DomainLabel is passed via env var (_COMPACT_DISKS_DOMAINLABEL),
    # not via -Command, because powershell.exe -Command's quoting around an
    # embedded -DomainLabel '...' argument was unreliable in practice (the
    # parent process ended up with $DomainLabel empty and the worker title
    # fell back to '<count> VM(s)'). Env vars are inherited verbatim by the
    # child process so there's no shell-quoting layer to fight.
    $command = "& '$scriptPath' -Mode $Mode -MaxConcurrentJobs $MaxConcurrentJobs -VMNames @($vmListQuoted)"

    $psExe = (Get-Process -Id $PID).Path
    if (-not $psExe) { $psExe = 'powershell.exe' }

    $argList = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-Command', $command
    )

    Write-WhiteI -indent 0 "Launching Compact-Disks UI for $($VMNames.Count) VM(s)..."
    if ($DomainLabel) {
        $env:_COMPACT_DISKS_DOMAINLABEL = $DomainLabel
    }
    try {
        Start-Process -FilePath $psExe -ArgumentList $argList -WindowStyle Normal -UseNewEnvironment:$false | Out-Null
        Write-GreenCheck "Compact-Disks worker launched. A WPF progress window will appear shortly."
    }
    catch {
        Write-RedX "Failed to launch Compact-Disks.ps1: $($_.Exception.Message)"
    }
    finally {
        Remove-Item Env:\_COMPACT_DISKS_DOMAINLABEL -ErrorAction SilentlyContinue
    }
}

function Merge-VMCheckpointsForCompact {
    <#
    .SYNOPSIS
        Deprecated - the WPF worker (Compact-Disks.ps1) now performs per-VM
        prep (stop + checkpoint merge) in parallel with compaction.
    #>
    [CmdletBinding()]
    param ([object[]] $VMs)
    Write-Log "Merge-VMCheckpointsForCompact is deprecated; stop and merge now run inside the Compact-Disks WPF worker." -LogOnly
}

function select-OptimizeDomain {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain To Optimize")]
        [string] $domain
    )

    $CustomOptions = @{}
    $vms = get-list -type vm -DomainName $domain -SmartUpdate

    $vmsname = $vms | Select-Object -ExpandProperty vmName

    $response = Get-Menu2 -MenuName "Select VMs to Optimize in $domain" -Prompt "Select VMs to Compact" -additionalOptions $CustomOptions -OptionArray $vmsname -test:$false -MultiSelect -AllSelected

    if ($response -eq "ESCAPE" -or $response -eq "NOITEMS") {
        return "ESCAPE"
    }

    $selectedVMs = @($vms | Where-Object { $_.VmName -in $response })
    if (-not $selectedVMs -or $selectedVMs.Count -eq 0) {
        Write-RedX "No VMs selected."
        return
    }

    # The WPF worker does everything per-VM in parallel:
    #   online cleanup (if Running) -> graceful shutdown (with hard-stop
    #   fallback) -> merge checkpoints -> mount/cleanup/zero-fill/defrag ->
    #   Optimize-VHD. As each VM finishes its prep its disks join the compact
    #   queue, so slow-stopping VMs don't block fast ones. The worker dot-
    #   sources Common.ps1 itself to pick up $Common.LocalAdmin.
    Start-CompactDisksUI -VMNames ($selectedVMs | Select-Object -ExpandProperty VmName) -DomainLabel $domain

    Write-Host
    Write-Host "VHD compaction is running in a separate WPF window." -ForegroundColor Green
    Write-Host "The worker will stop, merge checkpoints, and compact each VM in parallel. VMs that were running at start will be auto-restarted when compaction finishes." -ForegroundColor DarkGray
    Start-Sleep -Seconds 3
}






function Select-DeletePending {


    Write-Log -Activity "These VMs are currently 'in progress', if there is no deployment running, you should delete them and redeploy"
    get-list -Type VM -SmartUpdate | Where-Object { $_.InProgress -eq "True" } | Format-Table -Property vmname, Role, SiteCode, DeployedOS, @{E = { "$($_.DynamicMinRam)-$($_.Memory)" }; L = "Memory" }, @{Label = "DiskUsedGB"; Expression = { [Math]::Round($_.DiskUsedGB, 2) } }, State, Domain, Network, SQLVersion | Out-Host
    Write-WhiteI "Please confirm these VMs are not currently in the process of being deployed."
    Write-OrangePoint "Selecting 'Yes' will permanently delete all VMs and scopes."
    $response = Read-YesOrNoWithTimeout -Prompt "Are you sure? (y/N)" -HideHelp -timeout 180 -Default "n"
    if (-not [String]::IsNullOrWhiteSpace($response)) {
        if ($response.ToLowerInvariant() -eq "y" -or $response.ToLowerInvariant() -eq "yes") {
            Remove-InProgress
            Get-List -type VM -SmartUpdate | Out-Null
        }
    }
}
