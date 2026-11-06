# OSD content and PXE failure diagnostics

Phase 11 automatically captures both sides of an OSD content failure beside the
VMBuild log. This includes a boot image that remains pending or `InstallRetrying`
after its convergence wait, not just terminal distribution failures. A failed
DP-local check also collects its feeding site's evidence. Existing site servers
are resolved from VM inventory when an expansion configuration omits them;
parent CAS evidence is included for a child Primary. Site-wide failures also
capture the source sites reported by the required OS content, including a
different Primary that owns the packages. Discovery stays within the deployment
domain; missing or invalid source-site metadata is reported.

The capture contains:

- Site-side `distmgr`, `PkgXferMgr`, `SMSProv`, `smsexec`, `sitecomp`, `sender`,
  `despool`, and `rcmctrl` logs, including `.lo_` rolled copies.
- Guest `InstallCMLog.log`, `DSC_Log.log`, and `DSC_Status.txt`, preserving Phase 8
  publication, targeting, recovery, and coverage decisions.
- `OsdDistributionState.json`: capture time, boot images, OS images, OS upgrade
  packages, their source sites and source/stored versions, targeting rows,
  distribution summaries, and detailed provider status. Provider queries have
  ten-second operation limits. Each package inventory is capped at 20 objects,
  and each related status class at 250 rows; truncation and errors are recorded.
  A failed inventory does not discard the independently measured inventories.
- DP-side `smsdpprov`, `SMSPXE`, `SMSDPMon`, and `PrestageContent` active and rolled
  logs. The actual `SMS_DP$` share path is preferred; other discovered log roots
  are retained separately rather than silently selecting a stale directory.
- `DpContent.txt` and `DpPxePayload.txt`: library/package presence, PXE service
  executable paths, candidate TFTP roots, forced filesystem inventory, file sizes
  and modification times, directory attributes/ACLs, and boot-WIM DataLib shape.
  The probe token, local Administrators, share permissions, and parent-directory
  ACLs are captured independently, even when payload enumeration is denied.

Log reads retain the last 4,000 lines of each file. Log inventories record the
original path, size, last-write UTC time, and read failures, so an old or unreadable
log is not mistaken for evidence from the current attempt. Payload inventory is
capped at 200 files per root and the DataLib probe inspects at most 100 definitions.
Diagnostic failures remain explicit and do not replace the original validation
failure.

## OS image and upgrade progress windows

Phase 8 verifies targeting, not completed installation. Phase 11 allows each
required package/DP/source-version target 15 minutes without verified forward
progress, with a **45-minute overall convergence hard cap** including preparation
and queueing. A first observed transfer start seeds that target's transfer window;
it is not proof of sustained I/O.

The no-progress window renews only for these package-correlated milestones:

- A distinct file copied to DP staging, identified by `PkgXferMgr`'s `Adding ...
  file in <package>.<version>` event and its sending thread. This is after the copy
  and before the remote provider's content-library add; it is not proof that the
  package is fully Installed.
- A completed package transfer to that DP.
- Local source content observed advancing from an older stored version to the
  required source version during this validation.

Pending-state changes, log-file freshness, temp-file size, open SMB handles,
repeated transfer starts, and repeated attempts to add the same file do not renew
the window. One package or DP cannot borrow another's progress. The existing
one-time `InstallRetrying` re-arm does not reset a deadline.

The evidence reader checks the last 10,000 lines of active and rolled
`PkgXferMgr` logs. Classic and CMTrace timestamps are normalized to UTC, and file
milestones are correlated chronologically to the sending thread's package, DP,
and source version. Previous attempts, future timestamps, other versions, and
different DP FQDNs are excluded. Uncorrelated records and probe errors are reported
as unmeasured. A late observation cannot resurrect an already expired window.

These are **file/stage-level observations, not live intra-file byte counters**.
A large SMB copy can be active without producing another file-completion event.
If that progress cannot be measured, the failure says *no verified progress*,
not that the copy was proved stalled. The documented DP status class has no
bytes-transferred property. The 45-minute hard cap applies even while milestones
continue advancing.

Progress and failure details include the observed stage, source/stored versions,
last evidence, distinct copied-file count, time without progress, per-target
deadline, and overall deadline. Validation still requires Installed content and
stops immediately on a known problem state. These are lab-validation timers,
not ConfigMgr client timeouts.

See Microsoft's [content distribution troubleshooting](https://learn.microsoft.com/en-us/troubleshoot/mem/configmgr/content-management/troubleshoot-content-distribution)
for the copy/provider-add sequence and sending-thread correlation, and
[SMS_DistributionDPStatus](https://learn.microsoft.com/en-us/intune/configmgr/develop/reference/core/servers/configure/sms_distributiondpstatus-server-wmi-class)
for the actual status properties.

Per-package failure details include timestamp-preserving active/rolled
`distmgr`, `PkgXferMgr`, `despool`, and `sender` tails. DP `smsdpprov` excerpts are
package-correlated; unrelated historical startup errors are not presented as the
package's failure. Full DP logs remain in the capture for wider investigation.
No additional redistribution, service restart, or database repair is introduced.

## Existing-site expansion behavior

Adding a DP targets the existing boot-image version instead of rebuilding the WIM
site-wide merely because a destination or its first PXE payload is new.
Publication still occurs for changed command support, a restored source WIM,
a newly set PXE flag, or a confirmed missing boot file on an Installed/current DP.
An unreachable or unreadable payload probe does not justify a rebuild.

Registered DPs must also allow the site workflow to open and enumerate the
`SMS_DP$` share itself; a provider row and an existing share alone are not readiness.
This is a transport-access check, not a binary-directory check. Site-server DPs
do not have to contain the remote-DP `sms\bin` layout. PXE payload probes separately
use the actual `SccmPxe` executable directory or WDS `RootFolder`.
An Access Denied result permits one guarded Phase 8 repair: restore the owning
site computer's local Administrators membership, the share's Administrators Full
grant, and missing SYSTEM/Administrators Full grants on the canonical local
`SMS_DP$` directory, plus `sms` and `sms\bin` for non-site-server DPs. A site server
is identified by its installed `SMS_EXECUTIVE` service. Other grants and protected ACLs are
preserved. Explicit denies, unreadable security descriptors, nonstandard paths,
and failed post-repair access checks fail visibly; no content-library/DataLib
reset, take-ownership operation, or service restart is performed.

Phase 11 reports an unreadable payload as **unmeasured**, not missing, and still
fails required coverage. A successful TFTP read can serve an old boot image while
SMB transfer of the current WIM fails with Win32 error 5.

In a hierarchy, a CAS replication-readiness timeout is a failure, never an
implicit ready/Active verdict. Cached ready flags are revalidated, and resumed
Primaries also wait for an explicitly verified CAS handoff before dependent work.
Phase 8 failure captures include current/rolled `rcmctrl`, `replmgr`, `sender`,
and `despool` logs, replication monitoring classes, and a bounded
`DRSReadinessFailure.json` with the last provider/SQL health observations.
These diagnostics identify an initialization blocker; they do not automatically
repair database replication or override ConfigMgr authorization.
The one-time automatic DRS reinit selects failed groups from
`RCM_ReplicationLinkStatus` for the exact CAS/Primary pair. It does not filter
`SMS_ReplicationGroup` using nonexistent site-pair properties or infer failure
from that class's catalog-wide `Status`. Only those group IDs are submitted to
the documented `InitializeData(ReplicationGroupID, SiteCode1, SiteCode2)` method;
nonzero or malformed results remain failures, and an accepted request is not
readiness. Selection/request errors are retained in the deadline snapshot.
Recovery calls have a maximum 60-second operation timeout capped by the remaining
DRS stage budget; no new request is submitted after that deadline.
Formatted monitoring values such as `50%` are parsed numerically before any
100-percent gate; invalid values are reported and suppress that gate.

Site-server documents also contain `ReplicationSqlState`: bounded read-only
initialization/link rows, relevant `dbo.Logs` errors, and Broker transmission
errors. SQL procedures can write initialization failure details to `dbo.Logs`
without writing them to `rcmctrl.log`. Each query has a 15-second timeout and a
200-row limit; connection/query failures and truncation remain explicit.
The API contract is documented in
[SMS_ReplicationGroup](https://learn.microsoft.com/en-us/intune/configmgr/develop/reference/core/servers/configure/sms_replicationgroup-server-wmi-class)
and [InitializeData](https://learn.microsoft.com/en-us/intune/configmgr/develop/reference/core/servers/configure/initializedata-method-in-class-sms_replicationgroup).
Phase 8 site failures also collect independent site-server documents from the
trigger and its configured CAS/Primary peers, even when no MP/RP is installed.
Those documents include current and rolled replication log bodies. A failed
peer capture is recorded without discarding the other side. Terminal Phase 8
failure notification follows bounded capture so CAS cancellation cannot stop
the evidence collection halfway through.

The Phase 8 coverage loop does not refresh content in `InstallPending` or
`ContentValidating`. A remaining incomplete/retrying target gets five minutes to
settle before one recovery attempt per DP/source version. Phase 11 still requires
current Installed content and a working PXE chain; a successful TFTP first-block
read alone does not prove that the current WIM is installed.

After updating the host and guest DSC release, rerun the affected deployment from
**Phase 8**, not just Phase 11: validation does not apply the permission repair or
rerun content distribution. Check the captured Phase 8 execution timestamp, not
only the Phase 11 host version, when confirming that new guest code ran.
In a hierarchy, update/rerun the CAS as well as its Primaries so both sides use
the verified-readiness handshake.
If it still fails,
include the site and DP captures above in the diagnostic archive; the change does
not claim to repair an unmeasured underlying transfer/provider error.

Offline regression checks:

```powershell
.\vmbuild\tools\Test-BootImageExpansion.ps1
.\vmbuild\tools\Test-DpAccessRecovery.ps1
.\vmbuild\tools\Test-CmHierarchyFailurePropagation.ps1
.\vmbuild\tools\Test-CmRoleFailureDiagnostics.ps1
.\vmbuild\tools\Test-ReplicationFailureCapture.ps1
.\vmbuild\tools\Test-DrsScopedReinitialization.ps1
.\vmbuild\tools\Test-ReplicationSqlDiagnostics.ps1
.\vmbuild\tools\Test-OsdContentFailureDiagnostics.ps1
.\vmbuild\tools\Test-PerfloadingOsdContentReconciliation.ps1
.\vmbuild\tools\Test-Phase11OsdContentState.ps1
```
