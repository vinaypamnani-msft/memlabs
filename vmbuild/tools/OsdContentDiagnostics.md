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

### Phase 11 probe identity and TFTP replies

ConfigMgr can give `SMS_DP$\sms\bin` only SYSTEM and Local Service access.
An elevated administrator's inability to enumerate that directory is not proof
that the payload is absent or that the site cannot transfer content. Required
DP-local PXE checks and DP failure captures run as SYSTEM through a uniquely named,
bounded scheduled task. Request/result files are restricted to SYSTEM and
Administrators, and the task and files are removed before the probe returns.
The worker limits are 270 seconds for local validation and 120 seconds for
failure capture, leaving cleanup time within the existing host-call deadlines.
An invalid identity/result, timeout, worker failure, or cleanup failure is reported
explicitly. No ConfigMgr directory permissions are changed by validation.

The site-side TFTP probe binds its UDP socket before sending the request and
temporarily allows inbound replies only from the resolved DP address to that
socket's local port and process. TFTP's first DATA block normally comes from a
server-selected transfer port, not UDP/69; an outbound UDP/69 request alone does
not guarantee that reply can pass a stateful client firewall. The uniquely named
local firewall rule is removed in `finally` on success and failure. Probe setup,
malformed replies, and cleanup errors fail required delivery coverage.

A timeout identifies the site-server probe's request/reply path, not every PXE
client's path. If `SMSPXE.log` records the matching request and `sending`, inspect
the return path and receiving host's firewall rather than claiming the responder
is down or rebuilding the boot WIM. Local policy can still prevent a probe reply;
the rule does not override explicit blocks or domain policy.

Failed TFTP probes now preserve their own probe ID, UTC start/end times, resolved
server, local/reply ports, process/executable, accepted request byte count, and
native socket error. A `Network.json` snapshot is taken **before** closing the
socket or removing its temporary rule. It includes the rule's actual
`ActiveStore` enforcement state, effective profile/local-rule-merge settings,
UDP socket ownership and process paths, PXE/firewall services, selected route,
interfaces, enabled UDP/Any-protocol rule candidates and their address,
application, service and policy-source filters. Rules are not selected by a
PXE-looking display name. Peer/UTC-correlated WFP packet/connection drops retain
their runtime filter IDs. Missing auditing, unreadable tables and truncation are
explicit; an empty event table is not proof that no packet was dropped.
The retained-rule limit is applied after enabled UDP/Any selection, so disabled
rules cannot crowd out an enabled blocker. GPO source names are explicitly queried.

On failure, the host also makes **one labelled diagnostic replay per failing
DP**, not one per boot package. Uniquely named `netsh trace` sessions run on the
site server and responder around that replay. They capture IPv4 UDP involving
the original responder, multilayer packet evidence and WFP events. Each ETL is
circular, limited to 8 MB, with packets truncated to 128 bytes; native commands
have a 20-second limit and remoting/copies have separate bounded deadlines.
The replay uses the original resolved IP so its traffic cannot silently escape
the capture filter after a DNS change. It never makes the original validation
pass, even if the replay serves DATA.

The replay defers slow network inventory. Both owned sessions are stopped in a
separate lightweight pass in `finally` **before** either endpoint's inventory,
hashing or copying, preventing slow client-side processing from evicting the
responder's replay from its circular buffer. A per-session stop-intent marker
also rejects queued starts and makes an already-running start stop its own
session if its acknowledgement races cancellation. Stop markers are retained
when verified collection/cleanup cannot finish.
Failure to create/protect/write stop metadata cannot suppress the exact owned
session's native stop. A validated native-stop acknowledgement also permits
independent ETL collection when confirmation-file persistence failed; the
metadata/cancellation limitation remains explicit in the evidence.
Authoritative stop and unreleased-start reconciliation execute in `finally`,
including actual asynchronous pipeline cancellation during directory/ACL/marker
work or the final start-intent inspection. Offline regressions exercise real
runspace `BeginStop` cancellation, not only thrown exceptions.
Existing named traces and global Packet Monitor
filters are not stopped or modified. ETLs are copied beside the VMBuild log and
SHA256-verified before their exact guest files/directories are removed. A failed
copy leaves the guest path in the evidence; a failed stop identifies the exact
owned session that needs attention. No firewall/audit policy, DP configuration,
content, or service is repaired/reset by this capture.

Include **all `*-Tftp-*` JSON and ETL files** with the usual site/DP logs.
`*-Evidence.json` links the original probe, before-cleanup network snapshots,
replay, endpoint snapshots, native trace command results, verified host ETLs and
any incomplete collection. Read packet/drop events to locate the failed leg;
nonempty ETLs do not by themselves prove an RRQ or DATA packet was captured.
The subsequent DP log capture preserves any replay activity, while the separate
original/replay timestamps prevent historical `SMSPXE` transfers being treated
as evidence for this failure.
An original, replay or post-stop JSON write failure is reported independently;
it cannot suppress the other snapshots, paired stops or verified ETL copies.

The built-in offline converter can render an endpoint ETL without starting a
capture or changing policy:

```powershell
netsh trace convert input="<endpoint.etl>" output="<endpoint.txt>" dump=TXT report=no
```

Compare the replay's actual RRQ and DATA tuple on both endpoints and inspect WFP
packet-drop/filter IDs. A running service is not proof of a UDP/69 binding, and
missing Security events can mean auditing was disabled.

### Testable theories for a stale PXE log and a TFTP timeout

The November 18 failure followed a PXE responder restart, with no contemporaneous
request in the collected log. That makes listener/binding and request-admission
faults plausible, but does not prove either. The diagnostic manifest now includes
`TheoryChecks`, with these hypotheses and their confirming measurements:

| Theory | Evidence that distinguishes it |
|---|---|
| Responder did not bind correctly after restart, or another process owns UDP/69 | `Responder-Before-Network.json` is collected before replay. Compare exact `RequestedPortEndpoints`/count, bound IP, service PID and process creation time with the post-replay responder snapshot. Requested-port rows are retained separately from the capped service-socket inventory. A failed endpoint query is not a measured zero. |
| Wrong/stale DNS or ARP, wrong route/NIC, or host virtual-network filtering | Compare the resolved DP IP with responder addresses, guest NIC/MAC and address state, peer/gateway neighbor state, and host VM adapter/switch/standard/extended ACL snapshots. Then locate the same RRQ in both endpoint ETLs. A MAC mismatch is meaningful only on the correct on-link path; a gateway MAC is not the remote server's MAC. |
| DP firewall/WFP rejects the RRQ | A DP-side request plus a matching drop/filter ID and effective rule/GPO data supports admission failure. A source RRQ absent at the DP instead directs attention to the intervening path. Missing or overwritten packet evidence remains unmeasured. |
| Client reply allowance is not active when the RRQ is sent, or DATA is blocked | `RuleBeforeSendJson` reads the exact rule from `ActiveStore` before sending, preserving lookup errors, enforcement and UTC interval. Compare it with request-accepted UTC, after-failure policy, server-selected transfer port and client ephemeral-port drop evidence. The read does not wait for policy or turn an unmeasured rule into a failed TFTP result. |
| Responder/file-serving path is unhealthy despite installed content | After captures stop and remote evidence collection completes, one separately labelled DP-local TFTP control requests the **same DP address and filename**. Compare local/remote results and actual `TftpErrorCode` (for example file-not-found versus access violation). Local success proves service capability only at control time, not that the earlier remote path worked. An unconfirmed capture stop suppresses this extra traffic. |
| Collected log is stale or no longer the active logging target | Snapshots record UTC/size of a clearly labelled service-relative `SMSPXE.log` candidate. Compare with the local protocol control and the subsequent SYSTEM DP log inventory. A successful control with unchanged candidate log demands logging/path investigation, not an assertion that no request reached the service. |

Pre-replay inspection and host-policy read failures are explicit and cannot
suppress independent captures. The DP-local control never makes original
validation pass, changes content, or restarts a service. Protocol and rule
diagnostic cancellation still closes the original socket and removes only its
owned reply rule; real runspace cancellation covers both new read boundaries.

For these **validation-only** corrections, update the host source and rerun
**Phase 11**. Rerun Phase 8 only when producer access or content distribution
actually needs repair, as described below.

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

For producer-access or content-distribution fixes, update the host and guest DSC
release and rerun the affected deployment from **Phase 8**, not just Phase 11:
validation does not apply the permission repair or
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
.\vmbuild\tools\Test-Phase11PxeProbes.ps1
.\vmbuild\tools\Test-CmHierarchyFailurePropagation.ps1
.\vmbuild\tools\Test-CmRoleFailureDiagnostics.ps1
.\vmbuild\tools\Test-ReplicationFailureCapture.ps1
.\vmbuild\tools\Test-DrsScopedReinitialization.ps1
.\vmbuild\tools\Test-ReplicationSqlDiagnostics.ps1
.\vmbuild\tools\Test-OsdContentFailureDiagnostics.ps1
.\vmbuild\tools\Test-PerfloadingOsdContentReconciliation.ps1
.\vmbuild\tools\Test-Phase11OsdContentState.ps1
```
