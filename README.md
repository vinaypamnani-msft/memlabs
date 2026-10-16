# memlabs

ARM Template and DSC configurations for deploying an Azure VM with Hyper-V, and for deploying ConfigMgr lab virtual machines on this Hyper-V host.

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

## Deployment resume preflight

Phase 0 verifies live Hyper-V inventory before preparing VMs. Runs that skip
Phase 1 (`-StartPhase 2` or later, `-Phase` without 1, or `-SkipPhase 1`) fail
if required lab VMs are missing. Hidden/external dependencies must exist even
on a new deployment. The existing AADClient automatic Phase 1 recovery remains
available. Missing ordinary VMs remain allowed when Phase 1 is scheduled to
create them. Failed Phase 0 preparation does not run incomplete-VM cleanup.

Phases 8 and 9 also check their DSC targets before snapshots or CM media
preparation. Missing-node preflight failures stop dispatch. Job-wait exceptions
and missing or malformed phase tallies fail the phase instead of advancing to
maintenance. Logs identify the missing targets or result-validation failure.

Validate with `vmbuild\tools\Test-PhaseFailurePropagation.ps1`.

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
Phase 11 fails an idle failed/canceled sync or an unreachable WSUS health check;
a populated catalog alone is not evidence that the latest sync recovered.

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
Before upgrading, advertised or orphaned older Driver 18 MSI registrations
in the same upgrade family are restored using `/i {ProductCode}` with explicit
license acceptance. Otherwise, their nested `RemoveExistingProducts` action
can fail its license check even when the new MSI received the property.
Registration recovery does not explicitly uninstall a driver, does not target
Driver 17 or newer versions, and must succeed before the upgrade is started.
Each legacy recovery has its own verbose MSI log; unavailable original MSI
sources fail the preflight instead of triggering destructive cleanup.

Validate with `vmbuild\tools\Test-Odbc18VersionEnforcement.ps1` in Windows PowerShell.

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

Validate this path with `vmbuild\tools\Test-AutomatedResumePreparation.ps1` and
`vmbuild\tools\Test-PhaseFailurePropagation.ps1`.

The `vmbuild\config\tests\CSTest5-A-CSPS-PSHA.json` test configuration uses SQL
Server 2022 for its SQLAO pair after SQL Server 2019 CU32 repeatedly raised
severity-22 internal engine errors during ConfigMgr database initialization on
the test host. The local primary-site SQL instance remains on SQL Server 2019,
so the same lab still covers both engine generations. Each SQLAO node receives
12 GB, up from 7 GB. Updating this file alone does not upgrade SQL or resize
existing deployed VMs; the SQLAO pair must be rebuilt for those changes.
