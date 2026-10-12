# memlabs

ARM Template and DSC configurations for deploying an Azure VM with Hyper-V, and for deploying ConfigMgr lab virtual machines on this Hyper-V host.

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

After exhausted retries, the normal VMBuild logs include execution identity,
elevation, PowerShell/Hyper-V module context, VMMS status, up to 100 inventory
entries, and up to 20 recent warning/error event identifiers per Hyper-V VMMS,
Hyper-V Worker, and System Service Control Manager channel (15-minute window).
The evidence worker has a 20-second wait limit; collection failures, limits, and
timeouts are explicit in the logs. Raw Notes and event payloads are not exported.
Missing required Windows maintenance metadata fails the VM rather than treating
it as successfully maintained. No VM or service is restarted by this retry path.

Validate this path with `vmbuild\tools\Test-VMMaintenanceNoteDiagnostics.ps1`.
