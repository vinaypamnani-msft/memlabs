# memlabs

ARM Template and DSC configurations for deploying an Azure VM with Hyper-V, and for deploying ConfigMgr lab virtual machines on this Hyper-V host.

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

## ConfigMgr SQL failure diagnostics

Phase 8 SQL evidence collection also covers login/database-open errors 4060 and
18456, Service Broker failures, and site-control failures. For errors 4060 and
18456, it records current CM database state and availability-group role,
synchronization state/health, and suspension status alongside SQL ERRORLOG
evidence. These errors do not trigger CHECKDB; existing corruption-error
CHECKDB collection remains unchanged.

Validate this path with `vmbuild\tools\Test-CmFailureDiagnostics.ps1`.

The `vmbuild\config\tests\CSTest5-A-CSPS-PSHA.json` test configuration allocates
12 GB to each SQLAO node (CS1SQLAO1 and CS1SQLAO2), up from 7 GB. Updating this
file alone does not resize existing deployed VMs.
