<#
.SYNOPSIS
    Diagnoses PS 7.6.2 Copy-Item -ToSession regression in Start-Job vs Start-ThreadJob vs direct.
.DESCRIPTION
    Runs three copy tests against a running VM:
      1. Copy-Item -ToSession inside Start-Job       (current Copy-ItemSafe approach)
      2. Copy-Item -ToSession inside Start-ThreadJob  (proposed fix)
      3. Copy-Item -ToSession directly                (baseline)
    Reports elapsed time and pass/fail for each.
.EXAMPLE
    cd C:\memlabs\vmbuild
    .\Test-CopyRegression.ps1
#>
param(
    [string]$VMName  # Optional: specify a VM name. If omitted, picks first running VM.
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

# Load memlabs Common.ps1 for Get-VmSession, Write-Log, credentials, etc.
. .\Common.ps1 -InJob

Write-Host "`nPS Version: $($PSVersionTable.PSVersion)" -ForegroundColor Cyan

# Find a running VM to test against
if (-not $VMName) {
    $runningVMs = Get-VM | Where-Object { $_.State -eq 'Running' } | Select-Object -First 5
    if (-not $runningVMs) {
        Write-Host "No running VMs found. Start a VM and retry, or pass -VMName." -ForegroundColor Red
        return
    }
    Write-Host "`nRunning VMs:" -ForegroundColor Yellow
    $runningVMs | ForEach-Object { Write-Host "  $($_.Name)" }
    $VMName = $runningVMs[0].Name
}
Write-Host "`nTesting against VM: $VMName" -ForegroundColor Cyan

# Create a small test file
$testDir = Join-Path $PSScriptRoot "temp"
if (-not (Test-Path $testDir)) { New-Item -Path $testDir -ItemType Directory -Force | Out-Null }
$testFile = Join-Path $testDir "copy-regression-test.txt"
"Test payload $(Get-Date -Format o)" | Set-Content $testFile -Force
$destPath = "C:\Windows\Temp"

$vm = Get-VM -Name $VMName
$vmId = $vm.VMId
$cred = New-Object System.Management.Automation.PSCredential ("$VMName\$($Common.LocalAdmin.UserName)", $Common.LocalAdmin.Password)

# Try domain cred too
$vmList = Get-List -Type VM -SmartUpdate | Where-Object { $_.vmName -eq $VMName }
$domainName = if ($vmList) { $vmList.Domain } else { "WORKGROUP" }
if ($domainName -and $domainName -ne "WORKGROUP") {
    $cred = New-Object System.Management.Automation.PSCredential ("$domainName\$($Common.LocalAdmin.UserName)", $Common.LocalAdmin.Password)
}

Write-Host "Using credential: $($cred.UserName)" -ForegroundColor Gray

# ────────────────────────────────────────────────
# Test 0: Verify direct PSDirect session works
# ────────────────────────────────────────────────
Write-Host "`n── Test 0: Create PSDirect session directly ──" -ForegroundColor Yellow
try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $ps0 = New-PSSession -VMId $vmId -Credential $cred -ErrorAction Stop
    $sw.Stop()
    Write-Host "  PASS - Session created in $($sw.ElapsedMilliseconds)ms (State: $($ps0.State))" -ForegroundColor Green
    Remove-PSSession $ps0 -ErrorAction SilentlyContinue
}
catch {
    Write-Host "  FAIL - Cannot create PSDirect session: $_" -ForegroundColor Red
    Write-Host "  Aborting remaining tests." -ForegroundColor Red
    return
}

# ────────────────────────────────────────────────
# Test 1: Copy-Item -ToSession directly (baseline)
# ────────────────────────────────────────────────
Write-Host "`n── Test 1: Direct Copy-Item -ToSession (baseline) ──" -ForegroundColor Yellow
try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $ps1 = New-PSSession -VMId $vmId -Credential $cred -ErrorAction Stop
    Copy-Item -ToSession $ps1 -Path $testFile -Destination $destPath -Force -ErrorAction Stop
    $sw.Stop()
    Write-Host "  PASS - Direct copy completed in $($sw.ElapsedMilliseconds)ms" -ForegroundColor Green
    Remove-PSSession $ps1 -ErrorAction SilentlyContinue
}
catch {
    $sw.Stop()
    Write-Host "  FAIL - Direct copy failed after $($sw.ElapsedMilliseconds)ms: $_" -ForegroundColor Red
}

# ────────────────────────────────────────────────
# Test 2: Copy-Item -ToSession inside Start-Job
# ────────────────────────────────────────────────
Write-Host "`n── Test 2: Copy-Item -ToSession inside Start-Job ──" -ForegroundColor Yellow
$jobScript = {
    $ps = New-PSSession -VMId $using:vmId -Credential $using:cred -ErrorAction Stop
    Copy-Item -ToSession $ps -Path $using:testFile -Destination $using:destPath -Force -ErrorAction Stop
    Remove-PSSession $ps -ErrorAction SilentlyContinue
    return $true
}
try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $job = Start-Job -ScriptBlock $jobScript
    $timeoutSec = 60
    $finished = $job | Wait-Job -Timeout $timeoutSec
    $sw.Stop()
    if ($finished) {
        if ($job.State -eq 'Completed') {
            $result = Receive-Job $job -ErrorAction Stop
            Write-Host "  PASS - Start-Job copy completed in $($sw.ElapsedMilliseconds)ms" -ForegroundColor Green
        }
        else {
            $err = Receive-Job $job -ErrorAction SilentlyContinue 2>&1
            Write-Host "  FAIL - Start-Job ended with state '$($job.State)' after $($sw.ElapsedMilliseconds)ms" -ForegroundColor Red
            Write-Host "  Error: $err" -ForegroundColor Red
        }
    }
    else {
        Write-Host "  FAIL - Start-Job TIMED OUT after ${timeoutSec}s (state: $($job.State))" -ForegroundColor Red
        # Check if the job process is stuck
        Write-Host "  Job HasMoreData: $($job.HasMoreData), ChildJobs: $($job.ChildJobs.Count)" -ForegroundColor Gray
        if ($job.ChildJobs.Count -gt 0) {
            $cj = $job.ChildJobs[0]
            Write-Host "  ChildJob State: $($cj.State), Output: $($cj.Output.Count), Error: $($cj.Error.Count), Progress: $($cj.Progress.Count)" -ForegroundColor Gray
        }
        Stop-Job $job -ErrorAction SilentlyContinue
    }
    Remove-Job $job -Force -ErrorAction SilentlyContinue
}
catch {
    $sw.Stop()
    Write-Host "  FAIL - Start-Job test threw: $_" -ForegroundColor Red
}

# ────────────────────────────────────────────────
# Test 3: Copy-Item -ToSession inside Start-ThreadJob
# ────────────────────────────────────────────────
Write-Host "`n── Test 3: Copy-Item -ToSession inside Start-ThreadJob ──" -ForegroundColor Yellow
$threadScript = {
    $ps = New-PSSession -VMId $using:vmId -Credential $using:cred -ErrorAction Stop
    Copy-Item -ToSession $ps -Path $using:testFile -Destination $using:destPath -Force -ErrorAction Stop
    Remove-PSSession $ps -ErrorAction SilentlyContinue
    return $true
}
try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $tjob = Start-ThreadJob -ScriptBlock $threadScript
    $finished = $tjob | Wait-Job -Timeout $timeoutSec
    $sw.Stop()
    if ($finished) {
        if ($tjob.State -eq 'Completed') {
            $result = Receive-Job $tjob -ErrorAction Stop
            Write-Host "  PASS - Start-ThreadJob copy completed in $($sw.ElapsedMilliseconds)ms" -ForegroundColor Green
        }
        else {
            $err = Receive-Job $tjob -ErrorAction SilentlyContinue 2>&1
            Write-Host "  FAIL - Start-ThreadJob ended with state '$($tjob.State)' after $($sw.ElapsedMilliseconds)ms" -ForegroundColor Red
            Write-Host "  Error: $err" -ForegroundColor Red
        }
    }
    else {
        Write-Host "  FAIL - Start-ThreadJob TIMED OUT after ${timeoutSec}s (state: $($tjob.State))" -ForegroundColor Red
        Stop-Job $tjob -ErrorAction SilentlyContinue
    }
    Remove-Job $tjob -Force -ErrorAction SilentlyContinue
}
catch {
    $sw.Stop()
    Write-Host "  FAIL - Start-ThreadJob test threw: $_" -ForegroundColor Red
}

# ────────────────────────────────────────────────
# Test 4: Recursive directory copy inside Start-Job (matches Copy-ItemSafe pattern)
# ────────────────────────────────────────────────
Write-Host "`n── Test 4: Recursive dir copy inside Start-Job (Copy-ItemSafe pattern) ──" -ForegroundColor Yellow
$dscPath = Join-Path $PSScriptRoot "DSC"
$jobScript4 = {
    $ps = New-PSSession -VMId $using:vmId -Credential $using:cred -ErrorAction Stop
    # Create staging dir
    Invoke-Command -Session $ps -ScriptBlock { New-Item -Path "C:\staging\DSC-test" -ItemType Directory -Force } -ErrorAction SilentlyContinue
    Copy-Item -ToSession $ps -Path $using:dscPath -Destination "C:\staging\DSC-test" -Recurse -Container -Force -ErrorAction Stop
    Remove-PSSession $ps -ErrorAction SilentlyContinue
    return $true
}
try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $job4 = Start-Job -ScriptBlock $jobScript4
    $finished = $job4 | Wait-Job -Timeout 120
    $sw.Stop()
    if ($finished) {
        if ($job4.State -eq 'Completed') {
            $result = Receive-Job $job4 -ErrorAction Stop
            Write-Host "  PASS - Recursive Start-Job copy completed in $($sw.ElapsedMilliseconds)ms" -ForegroundColor Green
        }
        else {
            $err = Receive-Job $job4 -ErrorAction SilentlyContinue 2>&1
            Write-Host "  FAIL - state '$($job4.State)' after $($sw.ElapsedMilliseconds)ms: $err" -ForegroundColor Red
        }
    }
    else {
        Write-Host "  FAIL - TIMED OUT after 120s (state: $($job4.State))" -ForegroundColor Red
        if ($job4.ChildJobs.Count -gt 0) {
            $cj = $job4.ChildJobs[0]
            Write-Host "  ChildJob Progress records: $($cj.Progress.Count)" -ForegroundColor Gray
        }
        Stop-Job $job4 -ErrorAction SilentlyContinue
    }
    Remove-Job $job4 -Force -ErrorAction SilentlyContinue
}
catch {
    $sw.Stop()
    Write-Host "  FAIL - threw: $_" -ForegroundColor Red
}

# ────────────────────────────────────────────────
# Test 5: Recursive directory copy inside Start-ThreadJob
# ────────────────────────────────────────────────
Write-Host "`n── Test 5: Recursive dir copy inside Start-ThreadJob ──" -ForegroundColor Yellow
$threadScript5 = {
    $ps = New-PSSession -VMId $using:vmId -Credential $using:cred -ErrorAction Stop
    Invoke-Command -Session $ps -ScriptBlock { New-Item -Path "C:\staging\DSC-test" -ItemType Directory -Force } -ErrorAction SilentlyContinue
    Copy-Item -ToSession $ps -Path $using:dscPath -Destination "C:\staging\DSC-test" -Recurse -Container -Force -ErrorAction Stop
    Remove-PSSession $ps -ErrorAction SilentlyContinue
    return $true
}
try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $tjob5 = Start-ThreadJob -ScriptBlock $threadScript5
    $finished = $tjob5 | Wait-Job -Timeout 120
    $sw.Stop()
    if ($finished) {
        if ($tjob5.State -eq 'Completed') {
            $result = Receive-Job $tjob5 -ErrorAction Stop
            Write-Host "  PASS - Recursive Start-ThreadJob copy completed in $($sw.ElapsedMilliseconds)ms" -ForegroundColor Green
        }
        else {
            $err = Receive-Job $tjob5 -ErrorAction SilentlyContinue 2>&1
            Write-Host "  FAIL - state '$($tjob5.State)' after $($sw.ElapsedMilliseconds)ms: $err" -ForegroundColor Red
        }
    }
    else {
        Write-Host "  FAIL - TIMED OUT after 120s (state: $($tjob5.State))" -ForegroundColor Red
        Stop-Job $tjob5 -ErrorAction SilentlyContinue
    }
    Remove-Job $tjob5 -Force -ErrorAction SilentlyContinue
}
catch {
    $sw.Stop()
    Write-Host "  FAIL - threw: $_" -ForegroundColor Red
}

# ────────────────────────────────────────────────
# Test 6: Concurrent recursive copies via Start-Job (simulates real build)
# ────────────────────────────────────────────────
$allRunning = Get-VM | Where-Object { $_.State -eq 'Running' }
$concurrentVMs = $allRunning | Select-Object -First 8
$concurrentCount = @($concurrentVMs).Count

if ($concurrentCount -ge 2) {
    Write-Host "`n── Test 6: CONCURRENT recursive dir copy via Start-Job ($concurrentCount VMs) ──" -ForegroundColor Yellow
    $outerJobs = @()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    foreach ($tvm in $concurrentVMs) {
        $tvmId = $tvm.VMId
        $tvmName = $tvm.Name
        # Each outer job simulates what a phase job does: Start-Job inside Start-Job
        # Relay variables through outer scope so inner $using: can resolve
        $outerScript = {
            $localVmId = $using:tvmId
            $localCred = $using:cred
            $localDscPath = $using:dscPath
            $innerScript = {
                param($iVmId, $iCred, $iDscPath)
                $ps = New-PSSession -VMId $iVmId -Credential $iCred -ErrorAction Stop
                Invoke-Command -Session $ps -ScriptBlock { New-Item -Path "C:\staging\DSC-test" -ItemType Directory -Force } -ErrorAction SilentlyContinue
                Copy-Item -ToSession $ps -Path $iDscPath -Destination "C:\staging\DSC-test" -Recurse -Container -Force -ErrorAction Stop
                Remove-PSSession $ps -ErrorAction SilentlyContinue
                return $true
            }
            $innerJob = Start-Job -ScriptBlock $innerScript -ArgumentList $localVmId, $localCred, $localDscPath
            $done = $innerJob | Wait-Job -Timeout 120
            if ($done -and $innerJob.State -eq 'Completed') {
                $null = Receive-Job $innerJob
                Remove-Job $innerJob -Force
                return "PASS"
            }
            else {
                $state = $innerJob.State
                $progress = if ($innerJob.ChildJobs.Count -gt 0) { $innerJob.ChildJobs[0].Progress.Count } else { 0 }
                Stop-Job $innerJob -ErrorAction SilentlyContinue
                Remove-Job $innerJob -Force -ErrorAction SilentlyContinue
                return "FAIL (state=$state, progress=$progress)"
            }
        }
        $outerJobs += @{ Name = $tvmName; Job = (Start-Job -ScriptBlock $outerScript) }
    }
    # Wait for all outer jobs
    $outerJobs.Job | Wait-Job -Timeout 180 | Out-Null
    $sw.Stop()
    $anyFailed = $false
    foreach ($oj in $outerJobs) {
        $j = $oj.Job
        if ($j.State -eq 'Completed') {
            $r = Receive-Job $j 2>&1
            $resultText = ($r | Where-Object { $_ -is [string] }) -join ''
            if (-not $resultText) { $resultText = "PASS" }
            $color = if ($resultText -like "PASS*") { "Green" } else { "Red"; $anyFailed = $true }
            Write-Host "  $($oj.Name): $resultText" -ForegroundColor $color
        }
        else {
            Write-Host "  $($oj.Name): OUTER TIMEOUT (state=$($j.State))" -ForegroundColor Red
            $anyFailed = $true
            Stop-Job $j -ErrorAction SilentlyContinue
        }
        Remove-Job $j -Force -ErrorAction SilentlyContinue
    }
    Write-Host "  Total: $($sw.ElapsedMilliseconds)ms" -ForegroundColor $(if ($anyFailed) { "Red" } else { "Green" })

    # ────────────────────────────────────────────────
    # Test 7: Concurrent recursive copies via Start-ThreadJob
    # ────────────────────────────────────────────────
    Write-Host "`n── Test 7: CONCURRENT recursive dir copy via Start-ThreadJob ($concurrentCount VMs) ──" -ForegroundColor Yellow
    $threadOuterJobs = @()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    foreach ($tvm in $concurrentVMs) {
        $tvmId = $tvm.VMId
        $tvmName = $tvm.Name
        $outerThreadScript = {
            $localVmId = $using:tvmId
            $localCred = $using:cred
            $localDscPath = $using:dscPath
            $innerThreadScript = {
                param($iVmId, $iCred, $iDscPath)
                $ps = New-PSSession -VMId $iVmId -Credential $iCred -ErrorAction Stop
                Invoke-Command -Session $ps -ScriptBlock { New-Item -Path "C:\staging\DSC-test" -ItemType Directory -Force } -ErrorAction SilentlyContinue
                Copy-Item -ToSession $ps -Path $iDscPath -Destination "C:\staging\DSC-test" -Recurse -Container -Force -ErrorAction Stop
                Remove-PSSession $ps -ErrorAction SilentlyContinue
                return $true
            }
            $innerJob = Start-ThreadJob -ScriptBlock $innerThreadScript -ArgumentList $localVmId, $localCred, $localDscPath
            $done = $innerJob | Wait-Job -Timeout 120
            if ($done -and $innerJob.State -eq 'Completed') {
                $null = Receive-Job $innerJob
                Remove-Job $innerJob -Force
                return "PASS"
            }
            else {
                $state = $innerJob.State
                Stop-Job $innerJob -ErrorAction SilentlyContinue
                Remove-Job $innerJob -Force -ErrorAction SilentlyContinue
                return "FAIL (state=$state)"
            }
        }
        $threadOuterJobs += @{ Name = $tvmName; Job = (Start-Job -ScriptBlock $outerThreadScript) }
    }
    $threadOuterJobs.Job | Wait-Job -Timeout 180 | Out-Null
    $sw.Stop()
    $anyFailed = $false
    foreach ($oj in $threadOuterJobs) {
        $j = $oj.Job
        if ($j.State -eq 'Completed') {
            $r = Receive-Job $j 2>&1
            $resultText = ($r | Where-Object { $_ -is [string] }) -join ''
            if (-not $resultText) { $resultText = "PASS" }
            $color = if ($resultText -like "PASS*") { "Green" } else { "Red"; $anyFailed = $true }
            Write-Host "  $($oj.Name): $resultText" -ForegroundColor $color
        }
        else {
            Write-Host "  $($oj.Name): OUTER TIMEOUT (state=$($j.State))" -ForegroundColor Red
            $anyFailed = $true
            Stop-Job $j -ErrorAction SilentlyContinue
        }
        Remove-Job $j -Force -ErrorAction SilentlyContinue
    }
    Write-Host "  Total: $($sw.ElapsedMilliseconds)ms" -ForegroundColor $(if ($anyFailed) { "Red" } else { "Green" })

    # ────────────────────────────────────────────────
    # Test 8: Concurrent direct copies (no nested job, pure PSDirect concurrency)
    # ────────────────────────────────────────────────
    Write-Host "`n── Test 8: CONCURRENT recursive dir copy DIRECT in outer job ($concurrentCount VMs) ──" -ForegroundColor Yellow
    $directOuterJobs = @()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    foreach ($tvm in $concurrentVMs) {
        $tvmId = $tvm.VMId
        $tvmName = $tvm.Name
        $directScript = {
            $ps = New-PSSession -VMId $using:tvmId -Credential $using:cred -ErrorAction Stop
            Invoke-Command -Session $ps -ScriptBlock { New-Item -Path "C:\staging\DSC-test" -ItemType Directory -Force } -ErrorAction SilentlyContinue
            Copy-Item -ToSession $ps -Path $using:dscPath -Destination "C:\staging\DSC-test" -Recurse -Container -Force -ErrorAction Stop
            Remove-PSSession $ps -ErrorAction SilentlyContinue
            return "PASS"
        }
        $directOuterJobs += @{ Name = $tvmName; Job = (Start-Job -ScriptBlock $directScript) }
    }
    $directOuterJobs.Job | Wait-Job -Timeout 180 | Out-Null
    $sw.Stop()
    $anyFailed = $false
    foreach ($oj in $directOuterJobs) {
        $j = $oj.Job
        if ($j.State -eq 'Completed') {
            $r = Receive-Job $j 2>&1
            $resultText = ($r | Where-Object { $_ -is [string] }) -join ''
            if (-not $resultText) { $resultText = "PASS" }
            $color = if ($resultText -like "PASS*") { "Green" } else { "Red"; $anyFailed = $true }
            Write-Host "  $($oj.Name): $resultText" -ForegroundColor $color
        }
        else {
            Write-Host "  $($oj.Name): OUTER TIMEOUT (state=$($j.State))" -ForegroundColor Red
            $anyFailed = $true
            Stop-Job $j -ErrorAction SilentlyContinue
        }
        Remove-Job $j -Force -ErrorAction SilentlyContinue
    }
    Write-Host "  Total: $($sw.ElapsedMilliseconds)ms" -ForegroundColor $(if ($anyFailed) { "Red" } else { "Green" })
}
else {
    Write-Host "`n── Skipping concurrency tests (need 2+ running VMs, found $concurrentCount) ──" -ForegroundColor Gray
}

# Cleanup
Remove-Item $testFile -Force -ErrorAction SilentlyContinue

Write-Host "`n── Summary ──" -ForegroundColor Cyan
Write-Host "Tests 1-5: Isolated (single VM, sequential)"
Write-Host "Test 6: Concurrent Start-Job→Start-Job (matches real build: nested jobs)"
Write-Host "Test 7: Concurrent Start-Job→Start-ThreadJob (proposed fix)"
Write-Host "Test 8: Concurrent Start-Job→Direct copy (no nesting, baseline)"
Write-Host ""
Write-Host "If Test 6 FAILs but 7/8 PASS, the nested Start-Job is the bottleneck."
Write-Host "If Test 6+7 FAIL but 8 PASS, any nested job under concurrency is broken."
Write-Host "If all concurrent tests FAIL, PSDirect itself can't handle this many concurrent copies."
Write-Host ""
