# OSD content and PXE failure diagnostics

Phase 11 automatically captures both sides of an OSD content failure beside the
VMBuild log. This includes a boot image that remains pending or `InstallRetrying`
after its convergence wait, not just terminal distribution failures. A failed
DP-local check also collects its feeding site's evidence. Existing site servers
are resolved from VM inventory when an expansion configuration omits them;
parent CAS evidence is included for a child Primary.

The capture contains:

- Site-side `distmgr`, `PkgXferMgr`, `SMSProv`, `smsexec`, `sitecomp`, `sender`,
  `despool`, and `rcmctrl` logs, including `.lo_` rolled copies.
- Guest `InstallCMLog.log`, `DSC_Log.log`, and `DSC_Status.txt`, preserving Phase 8
  publication, targeting, recovery, and coverage decisions.
- `OsdDistributionState.json`: capture time, boot-image source/stored versions,
  flags, targeting rows, distribution summaries, and detailed provider status.
  Provider queries have ten-second operation limits. Inventories are capped at
  20 boot images and 250 rows per related class; truncation and errors are recorded.
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

## Existing-site expansion behavior

Adding a DP targets the existing boot-image version instead of rebuilding the WIM
site-wide merely because a destination or its first PXE payload is new.
Publication still occurs for changed command support, a restored source WIM,
a newly set PXE flag, or a confirmed missing boot file on an Installed/current DP.
An unreachable or unreadable payload probe does not justify a rebuild.

Registered DPs must also allow the site workflow to open and enumerate
`SMS_DP$\sms\bin`; a provider row and an existing share alone are not readiness.
An Access Denied result permits one guarded Phase 8 repair: restore the owning
site computer's local Administrators membership, the share's Administrators Full
grant, and missing SYSTEM/Administrators Full grants on the canonical local
`SMS_DP$`, `sms`, and `sms\bin` directories. Other grants and protected ACLs are
preserved. Explicit denies, unreadable security descriptors, nonstandard paths,
and failed post-repair access checks fail visibly; no content-library/DataLib
reset, take-ownership operation, or service restart is performed.

Phase 11 reports an unreadable payload as **unmeasured**, not missing, and still
fails required coverage. A successful TFTP read can serve an old boot image while
SMB transfer of the current WIM fails with Win32 error 5.

The Phase 8 coverage loop does not refresh content in `InstallPending` or
`ContentValidating`. A remaining incomplete/retrying target gets five minutes to
settle before one recovery attempt per DP/source version. Phase 11 still requires
current Installed content and a working PXE chain; a successful TFTP first-block
read alone does not prove that the current WIM is installed.

After updating the host and guest DSC release, rerun the affected deployment from
**Phase 8**, not just Phase 11: validation does not apply the permission repair or
rerun content distribution. Check the captured Phase 8 execution timestamp, not
only the Phase 11 host version, when confirming that new guest code ran.
If it still fails,
include the site and DP captures above in the diagnostic archive; the change does
not claim to repair an unmeasured underlying transfer/provider error.

Offline regression checks:

```powershell
.\vmbuild\tools\Test-BootImageExpansion.ps1
.\vmbuild\tools\Test-DpAccessRecovery.ps1
.\vmbuild\tools\Test-OsdContentFailureDiagnostics.ps1
.\vmbuild\tools\Test-PerfloadingOsdContentReconciliation.ps1
.\vmbuild\tools\Test-Phase11OsdContentState.ps1
```
