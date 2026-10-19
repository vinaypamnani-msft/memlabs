# memlabs

ARM Template and DSC configurations for deploying an Azure VM with Hyper-V, and for deploying ConfigMgr lab virtual machines on this Hyper-V host.

## Windows Terminal settings safety

Host appearance updates validate the existing Terminal settings, write and
flush a separate file in the same directory, validate that staged JSON, then
atomically replace `settings.json`. The previous file is retained byte-for-byte
as `settings.json.memlabs.bak` beside it. MemLabs writers coordinate through
`settings.json.memlabs.lock`; a detected intervening external edit is not
overwritten. Failed staging or replacement leaves the live settings untouched
and reports a warning without blocking lab deployment. Invalid existing JSON
is not automatically reset or repaired. An interrupted staging write can leave
an unused `settings.json.memlabs-<id>.tmp`, but does not truncate the live file.
These protections do not cover unrelated programs writing settings directly
or filesystem/storage corruption.

## Skipping an unreliable test family

Use `-SkipTest` to exclude one or more test families from a curated run:

```powershell
.\vmbuild\Start-Test.ps1 -All -SkipTest CSTest5
```

The option also applies to `-Suite` and `-Continuous`. Skipped families are
reported separately and are not recorded as completed tests. Unknown family
names fail immediately instead of being silently ignored. CM media mounting
also suppresses guest-probe noise while a target VM is powering on and starts
an off target once when attached media needs to be enumerated.

## Main-to-develop maintenance qualification

`Start-Test.ps1 -MainToDevelopExpansion` (also `-Suite Upgrade`) automatically
qualifies maintenance as part of the pinned main-A / develop-B+ cycle:

```powershell
.\vmbuild\Start-Test.ps1 -All -MainToDevelopExpansion -CrossRevisionPlanOnly
.\vmbuild\Start-Test.ps1 -All -MainToDevelopExpansion
```

- Before live candidate work, the pinned develop worktree must be clean, its
  shipped DSC archive must match its source/build receipt, and the focused
  maintenance, console, ODBC, Phase 11, receipt, and expansion-runner regressions
  must pass.
- Before expanding an exact-main baseline, develop runs **existing-site**
  maintenance without replacing the guest's legacy deployment configuration.
  Independent checks verify ODBC registration/DLLs in both registry views,
  installed MSI/cache state, live-site console policy, and the exact
  domain-qualified Full Administrator. A second maintenance run must add no
  attempts for the three implicated fixes.
- Each develop fixture/pass gets independent readiness checks before being
  checkpointed complete. VM/disk lineage and domain SID checks remain enabled.
  First-pass expansion VM/disk and applicable domain identities are persisted
  before maintenance gates and stage completion, so the second pass can verify
  the same machines. Resume validates saved identities instead of replacing
  them with the current inventory. Completed first-pass stages from older
  checkpoints that lack these identities capture them only after live stage
  and domain-health validation; this does not prove pre-capture continuity.
- Before retained-VM validation or live maintenance, the runner verifies saved
  VM identity and prepares domain-joined targets even when a deployment stage
  is skipped. An `Off` VM is started once by its verified Hyper-V object;
  `Starting`/`Stopping` transitions are observed without reset or hard power-off.
  Each target has a ten-minute readiness budget, including bounded PowerShell
  Direct probes by VM GUID that verify computer, user, and DNS-domain identity.
  Saved, paused, critical, replaced, or persistently unready VMs fail explicitly.
  START/WAIT/PASS output records the target GUID and power/transport evidence;
  existing domain SID, secure-channel, DNS, disk, and maintenance checks still
  run afterward. This also handles a graceful shutdown finishing after an
  earlier runner has exited. It does not certify the original reboot cause.
  Legacy VM notes without a NetBIOS domain name reuse the exact name from the
  matching saved baseline/expansion domain identity, allowing the NetBIOS
  credential fallback when a guest rejects UPN authentication. Conflicting
  saved names fail explicitly; no DNS-label guess is used. Readiness failures
  retain every attempted credential's transport error and PowerShell error ID.
- Once per candidate revision, a scoped CAS or standalone Primary runs the
  recovery matrix: missing legacy/current MSI source and installer cache,
  advertised/missing registration, missing console version metadata,
  preservation of a newer console without launching setup, administrator-role
  removal/regrant, a real failed attempt followed by the one-minute retry with
  evidence saved first, signed-package identity rejection without changing
  MSI/driver state or success stamps, and recovery using the actual shipped
  DSC resource. Side-by-side ODBC Driver 17 must remain unchanged.

These are **disposable-lab tests**: the matrix deliberately removes ODBC MSI
sources/cache/registration and temporarily changes guest console/configuration
and administrator state. Only explicit saved VM names/GUIDs are targeted; it
does not select unrelated host VMs. It restores the temporary configuration and
console-version fixtures and creates no qualification checkpoints. Expect
additional Microsoft MSI downloads/install time and at least one intentional
60-second retry. The configured setup administrator must be able to manage
ConfigMgr and must not be the administrator whose role is removed.

Machine-readable JSON receipts are saved as `*.qualification.log` under
`vmbuild\logs\CrossRevision\Maintenance` for normal log collection. They record
the pinned revisions, source/module/archive hashes, VM identities, individual
case results, and recovery evidence. Checkpoint state stores their SHA-256
checksums. Missing, stale, dirty-source, incomplete, or changed receipts block
family completion and cleanup; failures retain the VMs.
Runner failures also record the error ID, source position, script stack, and
current step in checkpoint `LastErrorDetails`, and print the source/stack beside
the failure. Missing VM identity entries fail explicitly before Hyper-V calls
rather than surfacing an empty `Get-VM -Name` argument.

Receipts use short, unique temporary names in the same directory for atomic
replacement. Full revision and receipt names stay intact without appending a
second GUID that can exceed Windows PowerShell's legacy path limit.

NOCM families record explicit `NotApplicable` recovery cases and **do not**
qualify the CM recovery matrix. Include a CM family to claim that coverage.
Interrupted maintenance resumes its original scoped stage before deployments
continue; do not advance develop until that stage has completed. Interrupted
deployments finish before new maintenance faults are injected. Older
checkpoints that have already expanded or cleaned a family cannot establish
this coverage: remove the old family lab and use a fresh
`-CrossRevisionStateRoot`. A rolling multi-revision burn-in remains diagnostic,
not a substitute for a fresh pinned qualification cycle.

Validate the receipt/gating contract with
`vmbuild\tools\Test-MaintenanceQualification.ps1` and the existing
`vmbuild\tools\Test-MainToDevelopExpansionRunner.ps1` regressions.

Runner regressions also account for the real harness holding the host mutation
lock during preflight. The log-recovery CLI must reject that concurrent context
and leave evidence untouched; when the lock is available, its normal log
migration is verified. Preflight never releases or weakens the production lock.

## Deployment resume preflight

Phase 0 verifies live Hyper-V inventory before preparing VMs. Runs that skip
Phase 1 (`-StartPhase 2` or later, `-Phase` without 1, or `-SkipPhase 1`) fail
if required lab VMs are missing. Hidden/external dependencies must exist even
on a new deployment. The existing AADClient automatic Phase 1 recovery remains
available. Missing ordinary VMs remain allowed when Phase 1 is scheduled to
create them. Failed Phase 0 preparation does not run incomplete-VM cleanup.

Existing `OSDClient` VMs are PXE targets, not Windows guest-readiness dependencies.
Phase 0 applies requested CPU/RAM changes without starting powered-off targets
or probing Windows heartbeat, PowerShell Direct, or guest paths. A running
target stopped for hardware changes is restarted without Windows readiness
checks, including when an update fails. Live Hyper-V reads verify the VM identity,
CPU/RAM settings, and original power state before success is reported. An ignored
hardware write cannot pass preparation. Saved/paused targets remain untouched
unless hardware changes are requested, in which case preparation fails with
instructions rather than discarding their state. Already-dynamic running targets
defer deployment-floor adjustments until they are off; those pin-only changes
neither interrupt PXE nor enter the potentially blocking live `Set-VMMemory`
path. Enabling a newly requested dynamic-memory policy still uses a controlled
stop/update/start.

Recognized transient Hyper-V/RPC errors and empty VM reads retry at most three
times, five seconds apart; permanent errors fail immediately. Power transitions
receive at most six observations, five seconds apart, and hardware readback
mismatches receive at most three observations. Stop/start use the existing bounded
power-control recovery helpers, not Windows boot probes or repeated guest resets.
Graceful-stop waits are 30 seconds per attempt; start retains the shared helper's
memory-pressure backoff, mount recovery, and diagnostics.
Logs include the operation, retry/observation count, VM identity/state, heartbeat
(diagnostic only), requested/actual hardware, recovery errors, and elapsed time.
Exception HRESULT chains support transient-error classification on localized
hosts. A failed update remains a failure even if power recovery succeeds; any
partially applied hardware is reported and can be reconciled by an idempotent
retry rather than an automatic rollback.
Missing/replaced VMs, failed writes, and failed power recovery never become
success. Resuming Phase 0 cannot recreate a VM after a failed inventory lookup.
Ordinary Windows VMs retain their guest-readiness checks. Initial OSD VM creation
remains in Phase 1.

Phases 8 and 9 also check their DSC targets before snapshots or CM media
preparation. Missing-node preflight failures stop dispatch. Job-wait exceptions
and missing or malformed phase tallies fail the phase instead of advancing to
maintenance. Logs identify the missing targets or result-validation failure.

Validate with `vmbuild\tools\Test-PhaseFailurePropagation.ps1`,
`vmbuild\tools\Test-AutomatedResumePreparation.ps1`, and
`vmbuild\tools\Test-OsdClientResumePreparation.ps1`.

### Phase 2 DSC staging recovery

A healthy Hyper-V heartbeat does not guarantee that PowerShell Direct can open
a session. Phase 2 checks that DSC module inspection actually succeeded before
treating an absent archive or signature as a payload that needs copying. A broken
channel or timeout enters the existing guarded guest-readiness recovery once,
with a 10-minute window, then retries the inspection. That shared recovery waits
through ordinary reboots and requires repeated broken-channel evidence before
rebooting a guest with a healthy heartbeat; authentication errors do not trigger
this recovery.

Failed recovery, failed inspection, and incomplete inspection output stop staging
with the connection or inspection diagnostic instead of repeatedly attempting
copies to an unreachable guest. This automatic recovery is limited to Phase 2.
Resume the retained deployment with `-StartPhase 2` after updating the runner.

Validate with `vmbuild\tools\Test-DscPayloadReadiness.ps1`.

### Shutdown cleanup after PowerShell Direct timeouts

A timed-out connection can remain in `Stopping` while blocked inside a Hyper-V
socket call, even after all PowerShell jobs have been removed. Disposing that
PowerShell instance synchronously waits for the connection and can hang shutdown
after the console's final dynamic-memory-restoration header.

Orphan cleanup, including worker and end-of-run `-Force` passes, leaves active
PowerShell invocations, nonterminal jobs, and busy runspaces untouched. `-Force`
only bypasses the minimum age. Deferred resources remain parked for a later safe
cleanup or process exit, and their count is logged. Terminal resources are still
reclaimed in the normal order.

The dedicated pinned-child launcher publishes the structured result, runs normal
PowerShell exit actions (including buffered-log flushing), then exits its owned
process without waiting for abandoned runspaces. The original exit code is
preserved. This does not terminate the parent test harness or any lab VM.

Validate with `vmbuild\tools\Test-OrphanRunspaceCleanup.ps1`.

### Phase 8 ConfigMgr proxy scope

ConfigMgr proxy enable/disable runs against the connected site's systems only.
A primary also manages its configured secondary sites; other primaries run their
own workflow, including in CAS hierarchies. Unrelated sites in the same deployment
are not treated as missing systems. Missing systems or failed proxy changes
inside the owned scope still fail the workflow for retry.

Validate with `vmbuild\tools\Test-CmProxySiteScope.ps1` and
`vmbuild\tools\Test-CmRoleQuerySiteScope.ps1`.

## Upgrade release health and recovery

Phase 8 probes the configured SUP machines, including remote SUPs, rather than
assuming WSUS runs on the site server. Native running synchronization is preserved
even when ConfigMgr still reports an older failure. Idle failed/canceled syncs
receive bounded recovery; unreadable native health and exhausted recovery fail
the workflow instead of silently advancing. Repair hardens/restarts WsusPool on
the SUP and captures its WSUS diagnostics. Long-running healthy background syncs
remain asynchronous and are reported as pending, not as proven completion.
After a bounded final-recovery wait, Phase 8 re-probes every configured SUP. A
replacement sync that is still running is preserved as pending rather than
failing and replaying prepopulation; an idle failed replica or unreadable
post-recovery health still fails the workflow.
The final WSUS health-check helper is defined at script scope, independently of
downstream replica repair, so CAS, standalone primary, and child primary runs
can all call it. Sites without a configured SUP skip this check.
Before prepopulation, Phase 8 checks that every required WSUS helper has exactly
one script-scope definition. Missing, nested, duplicate, or unparseable definitions
fail immediately without retrying object creation. The collected full
`InstallCMLog.log` records the guest script path, SHA-256, PowerShell version,
and helper line/scope inventory, including on contract failure. Validate this
guard with `vmbuild\tools\Test-PerfloadingContract.ps1`; log transport is covered
by `vmbuild\tools\Test-CmFailureDiagnostics.ps1`.
Phase 11 fails an idle failed/canceled sync or an unreachable WSUS health check;
a populated catalog alone is not evidence that the latest sync recovered.
Native results/state are read directly from the subscription API, without the
heavyweight `GetStatus()` client/compliance aggregation. A separate scoped update
count is informational: an unavailable count warns, is never treated as zero,
and cannot mask a failed or unreadable native sync. Failed/unreachable checks and
unavailable counts trigger bounded WCM/wsyncmgr and SUP SoftwareDistribution/IIS
evidence capture, including the configured upstream SUP for downstream faults.
The WSUS collector pulls the current `SoftwareDistribution.log` and up to two
newest rolled copies (`SoftwareDistribution.log*`), retaining at most 3,000 lines
per file. Capture diagnostics record source paths, sizes, timestamps, captured
line counts, omitted older files, and read errors, so a rolled SOAP fault is not
lost merely because it is absent from the current log.
An upstream outside the deployment config or a failed capture is reported
explicitly. Validate these paths with `vmbuild\tools\Test-WsusSyncConvergence.ps1`.
CM failure diagnostics include the properties of up to three WSUS per-update
errors, limited to 1,200 characters per sample, rather than only their type names.
A `Canceled`/`UserCanceled` outcome is not proof of a service restart: SQL or
transport failures can precede cancellation. Idle failures still fail validation;
only a running replacement or a newer successful cycle supersedes the old failure.

For HTTPS client push, the guest requests host certificate pre-staging and waits
for a receipt matching both the deployment RunId and request ID. The host checks
each target in its own domain, retries computer policy/autoenrollment, and verifies
a current client-auth certificate with a private key and trusted chain. Missing
or failed receipts stop client push. Phase 11 uses the same readiness probe.
Enrollment command exit codes and recent autoenrollment events are diagnostic
evidence; a future policy cycle is no longer treated as successful readiness.

Existing provider-error diagnostics, bounded CIM-memory reboot recovery, Primary
OSD/baseline payload repair, and physical/version-aware DP content checks remain
enabled. A Pull DP distribution deadline is not cleared by assuming summarizer
lag: later content/version checks must establish recovery. Scheduled runtime
upgrades defer while a test cycle holds the host mutation lease.
Legacy heartbeat-subnet SQLAO addresses are not migrated automatically; warnings
identify rebuild/connectivity checks rather than implying migration was tested.
Missing WinGet diagnostics name the maintenance identity and explain that App
Installer must be registered for that user, not only an interactive administrator.

Focused regression scripts under `vmbuild\tools` include
`Test-WsusSyncConvergence.ps1`, `Test-WsusReplicaRecovery.ps1`,
`Test-PkiClientPrestage.ps1`, `Test-GuestCimMemoryRecovery.ps1`,
`Test-GuestMemoryDiagnostics.ps1`, `Test-PerfloadingProviderResilience.ps1`,
`Test-PrimaryPrepopulationPayload.ps1`, `Test-OptionalSecondaryDpCoverage.ps1`,
`Test-MaintenanceScheduledTask.ps1`, and `Test-WinGetMaintenance.ps1`.
Run the upgrade fixtures again against the exact release commit: earlier
mixed-revision successes do not validate subsequent recovery changes.

## VM maintenance failure diagnostics

VMBuild Phase 10 reads each target VM's Hyper-V metadata before applying fixes.
Failed reads are retried up to three times, with two- and four-second delays.
Each attempt records its host, lookup outcome, VM ID/state when available, Notes
length, SHA-256 fingerprint, and failure category. Parsed Notes snapshots include
only allowlisted diagnostic fields (VM name, role, domain, update timestamp,
deployment state, phase/version, and operating system), with strings limited to
256 characters. Credential fields and unknown/nested values are excluded.
Lookup errors retain their original message, error ID, exception type, and
HRESULT. JSON errors do not include the Notes payload.
Successful retries are recorded, and the validated metadata is reused for fix
selection and execution rather than immediately read again.
The first failed attempt also records execution context and VMMS status, even
when a subsequent retry succeeds.

Before dispatching Phase 10 or launcher maintenance, the parent captures its host context and live
inventory. For each dispatched target, parent and worker logs compare the
requested name, configured/cached GUIDs, cache timestamp, and live Hyper-V
name/GUID/host/state. Workers also probe the GUIDs resolved by the parent,
including when the worker has no cache. These are diagnostic probes only:
they do not change which VM maintenance targets, rename VMs, or rewrite Notes.
Execution context includes runspace identity, ComputerName/CimSession defaults,
PowerShell/CIM session endpoints, and a bounded safe cache identity snapshot
with its timestamp and dirty flag. Scriptblock defaults are not evaluated.
This distinguishes a name/Notes/cache
disagreement from a parent/worker host or lookup disagreement.

After exhausted retries, the normal VMBuild logs include execution identity,
elevation, PowerShell/Hyper-V module context, VMMS status, up to 100 inventory
entries, and up to 20 recent warning/error event identifiers per Hyper-V VMMS,
Hyper-V Worker, and System Service Control Manager channel (15-minute window).
The evidence worker has a 20-second wait limit; collection failures, limits, and
timeouts are explicit in the logs. Raw Notes and event payloads are not exported.
Inventory entries also contain bounded, allowlisted Notes name/domain/role
and Notes fingerprints, so identity evidence does not depend on a successful
lookup of the requested name. Parent-resolved targets retain the fuller safe
Notes snapshot even when the subsequent name lookup fails.
Missing required Windows maintenance metadata fails the VM rather than treating
it as successfully maintained. No VM or service is restarted by this retry path.

Validate this path with `vmbuild\tools\Test-VMMaintenanceNoteDiagnostics.ps1`.

### ODBC Driver 18 maintenance

ODBC Driver 17 is preserved and does not satisfy Driver 18 compliance. Both
maintenance and DSC explicitly select Driver 18's MSI features with
`ADDLOCAL=ALL`: `REINSTALL=ALL` alone only repairs previously installed features
and can return success for an SDK-only product without installing the driver.
Success requires Driver 18 registration and its DLL, not just an MSI product
entry or version marker. Install and repair logs are kept separately; failure
diagnostics include the core feature's selected state. An MSI upgrade can
internally replace the older Driver 18 product, so exit code zero alone is not
proof that a usable driver remains.
The validated MSI is retained under
`%ProgramData%\MemLabs\Installers\ODBC18\<version>` using Windows Installer's
registered package filename. This permits repair without the source-name
mismatch between DSC and maintenance. Recovery selects missing features
without `REINSTALL`, and only reinstalls an already-local core feature.
Before upgrading, advertised, orphaned, or missing-cache older Driver 18 MSI registrations
in the same upgrade family are restored using `/i {ProductCode}` with explicit
license acceptance. Otherwise, their nested `RemoveExistingProducts` action
can fail its license check even when the new MSI received the property.
Registration recovery does not explicitly uninstall a driver, does not target
Driver 17 or newer versions, and must succeed before the upgrade is started.
If the original source or Windows Installer cache is missing, recovery obtains
the matching historical Microsoft MSI and validates its Microsoft signature,
product code, package code, and upgrade family before restoring the source and
cache through Windows Installer. Only known official release links are used;
an unavailable or unverifiable match fails before upgrade rather than triggering
destructive cleanup. Registration recovery and original-source recovery retain
separate verbose MSI logs.

Validate with `vmbuild\tools\Test-Odbc18VersionEnforcement.ps1` in Windows PowerShell.

### Maintenance retries and evidence

ODBC, console upgrade, and ConfigMgr Full Administrator fixes retain the existing
two host execution attempts, but collect evidence before retrying and wait 60
seconds between attempts. Remote execution is bounded to 30 minutes for ODBC,
60 minutes for console setup, and 10 minutes for administrator/provider work.
Batches containing these fixes use the combined execution budget; unrelated
fixes keep their existing retry policy. No recovery path automatically reboots a VM.

Every fix execution retains its transcript and structured result under
`C:\staging\Fix\history\<FixName>`, with a unique attempt ID. Explicit failed
results cannot become successful because another command leaked pipeline output.
These three fixes also save timestamped `*.diagnostics.log` JSON files alongside
the host VMBuild logs. Collection has a 60-second remote-command budget and a
512 KB transfer limit. It captures identity/elevation, active and on-disk source
versions, fix hashes, allowlisted deployment version metadata, both ODBC registry
views and DLL state, MSI product/cache identities, services/processes, ten recent
installer events, and bounded tails of up to ten relevant logs (60 lines each).
Collection failures and limits are explicit; tokens, passwords, SAS signatures,
and URL credentials are redacted.

Console maintenance takes its version from the **installed site's maintained
console payload**, not stale or missing `cmOptions.Version`. It verifies the
payload's console version and the site's required extension version. An external
site upgrade therefore does not trigger a downgrade to the old deployment target.
A console newer than the live payload is preserved with a warning; exact
compatibility is not claimed. Phase 11 uses the same live-target/no-downgrade
policy. `Upgrade-Console.ps1 -CheckOnly` performs the read-only check.
The payload's site build comes from the site-published console extension metadata.
`ConsoleSetup.exe` is a bootstrapper that can retain an older baseline build;
its file version is diagnostic only, not evidence of a stale console payload.
Phase 11 reports console, extension, and source-build comparisons separately.

Console setup retries uninstall/install failures up to three times, does not
repeat a successful uninstall, and polls verification before reinstalling.
Incomplete or mismatched site/source builds stop before uninstall. Missing UI
directories can be restored instead of blocking recovery.

Full Administrator maintenance uses the configured setup administrator, checks
the exact domain-qualified `vmbuildadmin` principal, separates collection names
from security scopes, and retries provider readiness three times with 60-second
backoff. Attempt-owned PSDrives and directory-search resources are released.
ODBC diagnostics record attempted commands, exit codes, durations, payload hashes,
and expected/actual recovery identities. Existing advertised target products also
request cache restoration, not only older-product upgrades.

Validate with `vmbuild\tools\Test-MaintenanceFixRobustness.ps1`,
`vmbuild\tools\Test-ConsoleUpgradeRouting.ps1`, and
`vmbuild\tools\Test-Odbc18VersionEnforcement.ps1`.

## ConfigMgr SQL failure diagnostics

Phase 8 SQL evidence collection also covers login/database-open errors 4060 and
18456, Service Broker failures, and site-control failures. For errors 4060 and
18456, it records current CM database state and availability-group role,
synchronization state/health, and suspension status alongside SQL ERRORLOG
evidence. These errors do not trigger CHECKDB; existing corruption-error
CHECKDB collection remains unchanged.

Before ConfigMgr setup creates `CM_<sitecode>`, Phase 8 also runs a disposable
SQL storage-engine canary. It checks `master`, `model`, and `msdb`, creates a
temporary database, populates a table, creates a clustered primary key, checks
the table and database, and removes the database. Any DDL, integrity, or cleanup
failure stops setup before it can leave a partial site database.

The five-minute Phase 8 host timeline includes bounded recent System events
from disk, storage, NTFS, WHEA, Hyper-V, volume, and resource-exhaustion
providers. A critical CAS/DC abort writes a final `critical-failure` snapshot so
events immediately preceding the failure are not lost.

For SQL Always On, Phase 8 additionally uses the Phase 5 `TESTDB` AG member to
rehearse the risky path: it creates clustered-key DDL before a controlled
failover, creates and merges substantial synchronized row sets after the
listener moves to the partner, verifies the merged table, fails back, and
removes the temporary tables. Any post-failover failure triggers a
best-effort return to the recorded original primary before each temporary table
is cleaned independently. The AG must remain connected, healthy, and
synchronized throughout. For slower hosts, replica session timeout is at least
30 seconds, AG health-check timeout is at least 60 seconds, and each preflight
transition has one shared 15-minute stabilization window instead of multiplying
that wait across sequential listener and replica checks. It emits periodic
listener and replica progress messages, then fails closed instead of launching
ConfigMgr setup against an unstable AG. Listener probes use the configured listener port,
while direct replica readiness and failover commands use each SQL VM's engine
port; these ports are intentionally independent.

Validate these paths with `vmbuild\tools\Test-CmFailureDiagnostics.ps1`,
`vmbuild\tools\Test-Phase8PrerequisiteDiagnostics.ps1`, and
`vmbuild\tools\Test-Phase8DiagnosticTelemetry.ps1`. Failover recovery fault
injection is covered by `vmbuild\tools\Test-SqlAoSetupCanaryRecovery.ps1`.

Unattended `Start-Test` and mixed-revision deployments request a verified Phase
8 rollback snapshot without prompting. ConfigMgr setup is not dispatched when
that requested domain snapshot is incomplete, and a failed Phase 8 run exposes
restore metadata so the bounded automatic retry restores the rollback point
before relaunching setup. `-NoSnapshot` remains an explicit opt-out for callers
that accept an unrecoverable partial-install failure.

Phase 8 site-install workflow state is written through a validated atomic
replacement and cross-VM readers retry transient I/O or JSON failures before
failing with the source path. Explicit guest `-Failure` reports always terminate
the owning phase script; critical site-install and role boundaries also propagate
unhandled exceptions. A CAS update that exhausts its bounded retries persists
`UpgradeSCCM=Error`, captures `cmupdate.log`, `hman.log`, and
`dmpdownloader.log` retry evidence, and stops before any primary or dependent
role can enter an impossible wait. The hierarchy readers treat `Error` as
terminal and bound dependency waits to four hours.

Validate these contracts with
`vmbuild\tools\Test-GuestScriptMemoryBoundary.ps1`,
`vmbuild\tools\Test-ScriptWorkflowStateIo.ps1`, and
`vmbuild\tools\Test-CmHierarchyFailurePropagation.ps1`.

Critical DC/CAS aborts also finalize the phase elapsed time before returning the
failure tally, so result validation preserves the guest setup error instead of
replacing it with a malformed-tally exception.

Phase 8 projected CIM reads retry recognized out-of-memory failures three times,
including WMI `0x80041006` and the literal `Out of memory` message. Exhaustion
leaves an atomic, deployment-RunId-scoped request for the host. The host permits
one graceful reboot per affected VM per Phase 8 run, verifies PowerShell Direct,
WMI, DSC and scheduled-task readiness, then resumes the existing DSC configuration
and workflow step state without restoring a snapshot. A second request, failed
graceful reboot, readiness timeout, or resume failure fails the VM explicitly.
Other errors and stale requests never trigger this recovery.

Projected CIM reads separately retry `WBEM_E_PROVIDER_DISABLED` (`0x8004108A`)
for up to two minutes when the SMS Provider has been unloaded. The HRESULT is
recognized from the CIM error ID even when the exception message is generic,
and each retry's query timeout and delay are capped by the remaining budget.
These read-only retries neither consume the three-attempt memory retry budget
nor request a reboot. A persistent outage still fails coverage without treating
unknown provider state as missing content; coverage errors retain the CIM error
ID instead of claiming that a memory retry occurred.

Graceful resume/DSC restarts close only idle cached PowerShell Direct sessions
for the target VM before requesting shutdown. Busy or unverifiable cached
pipelines fail closed without disposal or shutdown. A Hyper-V shutdown job still
running after the initial 180-second wait is observed, not cancelled or treated
as proof of failure. The existing 30-minute no-progress watchdog watches VM
state/heartbeat/status; an uptime reset proves a guest restart and an `Off` state
permits a normal start. In-progress or stalled shutdown never permits hard
power-off, including when `AllowTurnOff` was requested. Timeout diagnostics in
the normal VMBuild log/JSONL include VM state, heartbeat, status, uptime, shutdown
job state, and the original shutdown result; late job errors are also retained.
These signals do not prove that Windows servicing itself is making progress.
Validate with `vmbuild\tools\Test-SmartVmRestartSafety.ps1` and
`vmbuild\tools\Test-AutomatedResumePreparation.ps1`.

Before that reboot, and again if memory recovery is exhausted, the host saves
`<VM>-Phase8-<timestamp>-<trigger>-MemoryDiagnostics.json` beside the VMBuild log.
The report includes the originating workflow process snapshot and error, guest
and host memory/commit counters, largest private-memory consumers, WMI/SQL/
PowerShell processes, pagefile configuration and usage, WMI provider-host quotas,
recent resource-exhaustion/WMI memory events, and Hyper-V assigned/demanded memory.
Native counters and process enumeration remain independent of WMI. Failed sections
are recorded explicitly, guest capture is bounded to 60 seconds, and diagnostic
failures do not prevent recovery or replace the original failure. Pressure
indicators identify possible causes, not a definitive diagnosis.

Validate this path with `vmbuild\tools\Test-GuestCimMemoryRecovery.ps1` and
`vmbuild\tools\Test-GuestMemoryDiagnostics.ps1`.

Client-package diagnostic snapshots run in a disposable PowerShell process with
a 60-second wall-clock limit, including local provider reads and remote node
probes. A timeout terminates only that diagnostic process, records
`DiagnosticTimedOut` and the error in `ClientPackageTimeline.jsonl`, and leaves
the authoritative coverage checks and remediation running. Failed captures are
disabled until a forced deadline capture. An unreadable provider query is
classified as `ProviderStateUnreadable`, never as a missing targeting row.
Targeting records use the supported `SMS_DistributionPoint` properties; package
versions remain on the package and summarizer records, not targeting records.
The analyzer also accepts older targeting records that contain version fields.
Validate this path with `vmbuild\tools\Test-Phase8DiagnosticTelemetry.ps1`.

The coverage work itself also runs in an owned worker process. The parent reports
progress every 30 seconds even while a provider or WinRM call is blocked, stops a
worker with no checkpoint for five minutes, and enforces the worker's stage
deadlines independently of its polling loop. Existing 10-minute DP resolution,
30-minute replication-link, and 12/45-minute content budgets remain; the existing
one-time repair extension is preserved. Final-state collection is bounded to
three minutes, legacy post-deadline DP diagnostics share a 60-second budget, and
the discovery refresh has a 60-second limit. An independent two-hour ceiling
guards the entire worker. The Windows Job Object also cancels nested diagnostic
workers, including when their owning process exits unexpectedly.

Coverage deadline/stall exhaustion records `CoverageTimedOut`, retains the last
checkpoint and required DP set, and **warns rather than failing Phase 8**. Existing
CIM memory retries and distribution re-arm cadences are retained; a killed
worker is not blindly replayed, since it may have already changed distribution
state. Non-timeout script/provider errors remain failures. Live host progress is
scoped to the current workflow RunId so an older worker cannot mask current work.

Phase 11 is authoritative after that warning. Every required regular DP, and any
Secondary DP with assigned push clients, must report the current production client
package version Installed even when a fallback DP is healthy. Missing packages/rows and
unreadable boundary coverage fail validation. Unassigned Secondary DPs retain
their optional grace/fallback behavior; foreign-site DPs are not judged from a
non-authoritative provider. Projected managed DPs remain in the validation scope
even when omitted from the current VM list.

Validate these contracts with `vmbuild\tools\Test-ClientPackageCoverageBounds.ps1`,
`vmbuild\tools\Test-Phase11ClientPackageCoverage.ps1`,
`vmbuild\tools\Test-OptionalSecondaryDpCoverage.ps1`, and
`vmbuild\tools\Test-StartTestHistory.ps1`.

Validate this path with `vmbuild\tools\Test-AutomatedResumePreparation.ps1` and
`vmbuild\tools\Test-PhaseFailurePropagation.ps1`.

The `vmbuild\config\tests\CSTest5-A-CSPS-PSHA.json` test configuration uses SQL
Server 2022 for its SQLAO pair after SQL Server 2019 CU32 repeatedly raised
severity-22 internal engine errors during ConfigMgr database initialization on
the test host. The local primary-site SQL instance remains on SQL Server 2019,
so the same lab still covers both engine generations. Each SQLAO node receives
12 GB, up from 7 GB. Updating this file alone does not upgrade SQL or resize
existing deployed VMs; the SQLAO pair must be rebuilt for those changes.

All SQLAO instances use the lab policy `MAXDOP = 1`, on both the primary and
secondary replica. Phases 4 and 8 configure this through `SqlMaxDop` without dynamic
allocation or an active-node-only restriction. Site setup also reapplies and verifies
the configured and effective values through each physical node's SQL port before
canaries, including checkpoint retries and already-installed site paths, and
again after each ConfigMgr setup attempt, including hierarchy primaries. Retained
single-node SQLAO instances are reconciled without requiring an absent partner.
This is an online instance setting;
the previous `show advanced options` state is restored after changing it.
Phase 11 fails SQLAO validation if either value has drifted from 1 or cannot be
read. Standalone and other non-SQLAO SQL instances retain their existing settings.
Serial execution is a lab policy, not a guaranteed fix for SQL engine error 5243.
Validate with `vmbuild\tools\Test-SqlAoMaxDop.ps1` and
`vmbuild\tools\Test-SqlAoSetupCanaryRecovery.ps1`.
