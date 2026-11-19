# Maintenance Fixes

Each `*.ps1` file in this folder defines exactly one maintenance fix.
They are dot-sourced from inside `Get-VMFixes` (`Common.Maintenance.ps1`),
so they execute in that function's scope.

## Contract

When dot-sourced, the file MUST:

1. Define a script block containing the fix body. The body runs **inside the
   target VM** via PSRemoting, wrapped by `New-VMFixScriptBlock` which
   provides:
     - a transcript at `C:\staging\Fix\<FixName>.txt`,
     - a `Write-FixLog` helper (`-Level Info|Warning|Failure|Success`),
     - a structured `[pscustomobject]` return shape:
       `@{ FixName; Success; Message; Errors; ExceptionInfo; ComputerName; StartedAt; DurationSec; IsStructured }`.
   The body should return either `$true`/`$false` OR a `[pscustomobject]@{ Success; Message; Errors }`.

2. Append a fix descriptor to the host-scoped `$fixesToPerform` array:
   ```powershell
   $fixesToPerform += [PSCustomObject]@{
       FixName             = '<Unique-Name>'        # also used as transcript filename
       FixVersion          = 'YYMMDD[.n]'           # monotonically increasing
       NeededOnFreshDeploy = $true                  # $true = core code doesn't cover this; run even on fresh builds. $false = core already produces this state; skip on fresh deploy
       AppliesToExisting   = $true                  # apply to existing VMs
       AppliesToRoles      = @()                    # empty = all roles
       NotAppliesToRoles   = @()                    # excludes
       DependentVMs        = @()                    # VM names that must also be online
       ScriptBlock         = $Fix_X                 # the body defined above
       ArgumentList        = @(...)                 # optional, forwarded to body's param block
       RunAsAccount        = $vmNote.adminName      # optional, run under specific account
       InjectFiles         = @('Foo.ps1')           # optional, copied to C:\staging\
       InjectTools         = @('LogMachine')        # optional, copied to C:\tools\
       PrepareScriptBlock  = { param($VMName, $VMDomain, $VMFix) ... } # optional, host-side preparation
   }
   ```

Host preparation runs only for pending, applicable fixes, after the VM connects
and before file injection or argument serialization, in both execution paths.
It can populate the descriptor's `InjectFiles` and `ArgumentList` properties.
It must throw on failure; a failed preparation is logged and prevents execution
and applied-version stamping.

## Available variables

- `$vmNote`    — `Get-VMNote` result for the target VM (`$null` for dummy list).
- `$dc`        — Domain controller VM in the same domain.
- `$Common`    — Global memlabs config (e.g. `$Common.LocalAdmin.Password`).
- `$NewVM`     — `$true` if this is a freshly-built VM.
- `$fixesToPerform` — array to append into.

## Adding a new fix

1. Drop a new `Fix-<Name>.ps1` here.
2. Bump `FixVersion` whenever the body changes meaningfully so existing VMs
   re-apply the fix.

Load order within this folder is alphabetical, but **runtime execution order**
is determined by `FixVersion` (sorted ascending), not load order.

## Console provider shutdown recovery

When [Fix-Upgrade-Console.ps1](Fix-Upgrade-Console.ps1) fails during Phase 10
or existing-VM maintenance, the host re-runs the same `SMS_ConsoleSetupInfo`
query before retrying the failed fix. A typed `WBEM_E_SHUTTING_DOWN`
(`0x80041033`) error, or a newly written, class-specific error in `SMSProv.log`,
permits **one graceful reboot of only that VM**. Historical log entries,
unrelated provider errors, and a generic "server threw an exception" alone
never trigger a reboot.

The host saves failure evidence before restarting, reconnects using the same
maintenance account, and allows up to 300 seconds for that exact query to
return a valid extension version. Only then is the console fix retried.
If the shutdown is first confirmed on the final ordinary attempt, one additional
attempt is allowed after recovery; it never grants another reboot.
Recovery never hard-powers off the VM, restarts WMI inside an active workflow,
or marks the fix applied without its normal explicit success marker.
Failed recovery remains a maintenance failure with diagnostics. Provisioning
and Phase 11 validation share the query helper but do not initiate this reboot.

Validate with [Test-ConsoleProviderRecovery.ps1](../tools/Test-ConsoleProviderRecovery.ps1),
[Test-MaintenanceFixRobustness.ps1](../tools/Test-MaintenanceFixRobustness.ps1),
and [Test-ConsoleUpgradeRouting.ps1](../tools/Test-ConsoleUpgradeRouting.ps1).
The recovery tests mock guest queries and VM restarts; they do not reboot a lab.

## Late Edge servicing

[Fix-EdgeServicing.ps1](Fix-EdgeServicing.ps1) runs during fresh-build Phase 10
and existing-VM maintenance, after early provisioning's intentional Edge Update
suppression. It is not seeded as already applied from a legacy version watermark.
Offline root CA, proxy, Linux, OSD, and AAD-client roles are excluded.

The host probes the guest's OS architecture and installed browser version, then
selects the current Windows Stable MSI using Microsoft's enterprise metadata.
An internet-connected host is required; the guest does not need internet access.
When an upgrade is needed, the host verifies the official HTTPS delivery origin,
exact file size, SHA-256, and valid Microsoft signature, then injects the MSI
through the existing `InjectFiles` path. Versioned packages are cached in the
host's `filesToInject\staging` directory; concurrent workers share a verified
download. Current/newer browsers need no MSI download or transfer.
The guest independently verifies the staged MSI's size, SHA-256 and Microsoft
signature before installation. Missing media or unavailable host metadata remains
an explicit failure, not an unverified success or a guest-download fallback.
It keeps newer installed versions, bounds downloads and the shared MSI retry
budget, records `C:\staging\Fix\EdgeServicing-MSI.log`, verifies the installed
version, and restores Edge updater services/tasks. The host execution limit is
1,200 seconds; the MSI budget is 600 seconds across at most three attempts.
After a successful MSI exit, browser-version verification allows up to 30 seconds
for completion within that same budget. If exit `0` leaves the browser outdated,
the next permitted attempt uses `REINSTALL=ALL REINSTALLMODE=vomus` against the
same verified MSI. A normal `/i` can otherwise skip the browser installer when
that MSI version is already registered. Repair is never used for the initial
installation, and an unchanged browser still fails after the bounded repair.
Later MSI attempts append to the log so the original no-op is retained.
The installed browser must meet the current Stable version for its architecture;
updater services are not manually started or required to remain running.
Their startup types and enabled scheduled tasks are still restored and verified.
Managed policies that prevent normal Stable updates cause an explicit failure
without registry-policy changes. Update services/tasks are also restored after
a failed guest-side verification or installation. Host preparation failures do
not run the guest fix or change its updater configuration.
No automatic reboot or forced browser termination is requested.
Existing browser windows must be reopened to use the updated engine.

On failure, the host automatically embeds Edge's MSI log, updater logs and
recent `msedge_installer*.log` files in its timestamped `.diagnostics.log`
sidecar, which is already included in build-log bundles. Small product logs
are captured in full; larger logs retain bounded tails (64K characters per log,
at most six logs). The shared 512 KB transfer limit can reduce those captures
further, with explicit truncation metadata. Missing or unreadable logs are
inventoried rather than silently omitted. Browser launcher/payload versions,
Edge registration, updater services/tasks and related processes are captured
as separate evidence; MSI product version alone is not browser verification.

Validate with [Test-EdgeServicing.ps1](../tools/Test-EdgeServicing.ps1).
The test uses mock installers, services, tasks, policy, and download responses.
Validate failure capture and host-side export with
[Test-EdgeFailureEvidence.ps1](../tools/Test-EdgeFailureEvidence.ps1).

## Windows activation on air-gapped VMs

[Fix_ActivateWindows.ps1](Fix_ActivateWindows.ps1) uses Azure KMS for unactivated
Windows Pro/Enterprise VMs hosted in Azure. If resolving `azkms.core.windows.net`
returns `DNS_ERROR_RCODE_REFUSED` (native DNS error 9005), the fix treats external
KMS access as blocked by the air gap. It logs an explicit activation skip and
returns success without further TCP probes or activation attempts. This does not
mean Windows was activated.

Other DNS errors, TCP connectivity failures, and unsuccessful activation retain
the existing retry and failure behavior. Already activated VMs remain a no-op,
and non-Azure hosts remain excluded.

Validate with [Test-WindowsActivationMaintenance.ps1](../tools/Test-WindowsActivationMaintenance.ps1).
The test mocks licensing and network commands; it does not change host activation.
