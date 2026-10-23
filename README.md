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

## Host ASP.NET Core runtime servicing

`vmbuild\Invoke-Maintenance.ps1` services installed system-wide ASP.NET Core
shared runtimes on VMBuild launch and in the daily **MemLabs Host Maintenance**
scheduled task. This covers runtimes installed outside Chocolatey/WinGet as
well as package-manager installations. It discovers installed stable branches
and architectures from disk, checks Microsoft's release metadata each run, and
installs the latest supported patch in the **same major/minor branch**. It does
not install ASP.NET Core on hosts that do not already have it, downgrade newer
patches, or remove whole runtime branches based on an assumption that they
are unused. ASP.NET Core is a shared dependency, not a standalone application;
its presence alone does not identify which application installed or needs it.

Downloads must match Microsoft's SHA-512 hash and have a valid Microsoft
Authenticode signature. **Security takes precedence over compatibility:**
identified superseded patches must be removed even if an SDK/application still
needs them, a test cycle is active, or installing the required replacement fails.
This can break applications or SDK operations until their dependencies are fixed.
Registered runtime bundles and exact runtime MSI products (including hidden
SDK-owned components) are uninstalled unattended without requesting a restart.
Remaining old files are then removed from their specific version directory,
regardless of installer ownership. SDKs and unrelated runtime families themselves
are not uninstalled.

Within the exact superseded version directory, cleanup accepts managed and native
DLLs (including `aspnetcorev2_inprocess.dll`), runtime manifests/version markers,
and `THIRD-PARTY-NOTICES.txt`. It rejects reparse points, nested directories, and
other unexpected files, uses literal file paths and a non-recursive empty-directory
delete, and clears read-only attributes on known old runtime files. It opens all old files before
deleting any to detect locks and prevent new readers during cleanup. Windows
locks/permissions or unsafe contents require administrator intervention; they
remain explicit failures, not exemptions or successful remediation. Maintenance
does not automatically reboot the host or force-close unrelated applications.
If metadata is unavailable, lower patches can still be removed when a newer
patch is already installed, but latest-version verification still fails.

Success requires the old directories **and matching runtime uninstall entries**
to be absent and the required target's files/version marker to verify. Failed
patching, uninstall/inventory errors, unsupported branches, or incomplete cleanup
fail maintenance even if some old files were removed. Prerelease/unrecognized
directories are preserved with a warning. SDK repair or external installers can
restore removed dependencies; a subsequent maintenance run enforces removal again.

Main maintenance logs and separate `AspNetCore_*.log` installer logs are under
`vmbuild\logs`. The nightly SYSTEM task waits for machine package upgrades before
the final security check. Because WinGet registration is user-scoped, interactive
maintenance also registers a hidden **MemLabs User WinGet Maintenance** task that
runs two minutes after logon, at most once per 24 hours. Normal VMBuild launches
dispatch due WinGet and daily package work to a visible background maintenance
window instead of waiting before opening the app. Both background entry points
run the final ASP.NET Core security check after their package work.
Applications already using a runtime may require restarting to load patched
files, and a vulnerability report may not clear until its next inventory scan.
Validate without changing host packages using
`vmbuild\tools\Test-AspNetCoreMaintenance.ps1` under PowerShell 7 and Windows
PowerShell 5.1.

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
  must pass. The **first regression** is `Test-MainToDevelopExpansionRunner.ps1`.
  It checks complete multi-VM maintenance scopes in fresh ordered dictionaries
  and restored checkpoints, then runs workflow-receipt regressions under
  PowerShell 7 and Windows PowerShell 5.1 and Phase 8 diagnostic regressions
  under PowerShell 7. These exercise real file-lock contention, bounded append
  retries, and recovery of the final snapshot. All three burn-in defects fail
  preflight before any VM deployment. The regression inputs and their production
  helpers are included in the pinned source digest.
  To run this initial gate alone without changing Hyper-V:

  ```powershell
  pwsh -NoProfile -File .\vmbuild\tools\Test-MainToDevelopExpansionRunner.ps1
  ```

  The Windows setup-readiness regression also runs with real
  background jobs under both PowerShell 7 and Windows PowerShell 5.1 before VM
  mutation, with separate required receipt cases for the two engines. Its test,
  command wrapper, shared probe, and phase wiring are included in the pinned
  source digest. A failure or missing engine blocks the candidate preflight.
  Console framebuffer regressions also run as separate required cases on both
  engines, with their helper, test, and collector sources included in the digest.
  They verify raw and validated length-prefixed RGB565, pixel orientation/stride,
  black-frame reporting, and rejection of malformed frames.
  The CIM proxy-temp regression also prevents cleanup from deleting shared
  proxy directories that may still back other live PowerShell sessions.
  Setup-diagnostic cold-launch checks verify omitted/explicit destinations and
  collect/repair routing through real `-File` launches under both engines, with
  VM operations replaced by no-op reports.
  Cancellation preflight uses windowless native child processes and verifies
  that no console is attached, while still checking parent/descendant teardown
  and checkpoint preservation.
- Before expanding an exact-main baseline, develop runs **existing-site**
  maintenance without replacing the guest's legacy deployment configuration.
  Independent checks verify ODBC registration/DLLs in both registry views,
  installed MSI/cache state, live-site console policy, and the exact
  domain-qualified Full Administrator. A second maintenance run must add no
  attempts for the three implicated fixes. Target deduplication uses saved VM
  names rather than dictionary properties and rejects conflicting GUIDs.
  A CAS/standalone Primary in the baseline fixture independently requires CM
  coverage in baseline and postcondition receipts; losing that VM cannot
  turn a CM family into a successful N/A receipt. Previously completed CM
  families with a DC-only/N/A gate fail instead of being skipped as qualified;
  use a fresh state root to requalify them.
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
  saved names fail explicitly; no DNS-label guess is used. Readiness timeouts
  retain the latest transport error and PowerShell error ID for every attempted
  credential across polls, even if the deadline interrupts the final credential
  pass. The runner regression exercises this boundary with a controlled clock.
- The host publishes and verifies the workflow RunId before launching DSC, not
  after a potentially long-running start call. Phase 8/9 cannot start without
  that verified identity. Workflow failures publish an atomic, RunId-bound
  failure receipt. Local and
  cross-node DSC receipt waits reject the matching failure immediately; the
  host also reads it independently so overwritten status text cannot hide it.
  Stale failures do not poison a replacement invocation. Elapsed-only receipt
  updates remain visible but do not reset progress/stall clocks, and receipt
  dependents track the actual owner VM. Existing bounded CIM-memory recovery
  still takes priority over the terminal-failure status.
- Phase 8 timeline writes retry transient exclusive-append contention. Exhausted
  writes warn and back off without disabling subsequent or final snapshots;
  final-capture failures are warnings too, not INFO-only evidence loss.
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
On a rolling run, completed families are checked against the required cases in
their own pinned Git revision, not a newer candidate's expanded case list.
The runner reads literal case lists from Git without executing historical code;
missing history or an unreadable contract fails closed. Current candidate
preflight still requires every current case, and historical receipts cannot
substitute for it. Receipt checksums, source identity, targets, statuses, and
CM recovery coverage remain enforced. Case-list failures report the candidate,
expected/actual counts, and missing, unexpected, or duplicate names.
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

### Windows client setup readiness

Ordinary Windows-client deployments require complete machine-setup state before
advancing. A successful native `OOBEComplete` Windows Welcome signal still passes
the normal completion path. There is also an explicit unattended-machine-ready
state, `MachineCompleteAwaitingFirstLogon`, for a guest that has not started its
first-user OOBE. This requires **all** of:

- `IMAGE_STATE_COMPLETE` and numeric zero `SetupType`, `SystemSetupInProgress`,
  and `OOBEInProgress`.
- A successful native API query reporting incomplete, with the WinRT
  `SystemSetupInfo` OOBE lifecycle API reporting exactly `NotStarted`.
- Numeric `setup.exe` child completion state `3` and readable active/pending names.
- A successful bounded process query finding no setup, OOBE UI/execution,
  CloudExperienceHost, WWAHost, or first-logon-animation hosts. The exact
  `CloudExperienceHostBroker.exe` support broker is still recorded but does not
  alone prove active OOBE once every other machine/API guard has passed.

`OobeProcessCount`/`OobeProcesses` retain every observed matching process;
`OobeBlockingProcessCount` distinguishes execution/UI hosts from the resident
support broker. A broker alongside any blocking host remains blocked. The host
also validates the observed count/names, so an unknown process cannot be hidden
behind a zero blocking count.

This classification permits unattended deployment before interactive first logon;
it does not claim native OOBE completion. `InProgress`, active OOBE processes,
incomplete machine setup, conflicting API signals, missing/malformed values, and
API/query errors remain blocked. `IMAGE_STATE_COMPLETE` alone is insufficient:
failed user OOBE can still re-arm setup or change the computer name.

The mandatory client gate runs after fresh-VM machine readiness, before
retained-VM resume reboot checks, and again after any required resume reboot.
It uses a 30-minute polling deadline, bounded guest-command probes, and reports
the setup flags, native/WinRT OOBE states, child completion, process evidence,
active/pending names, and read errors.
Malformed responses also report envelope/setup-state object counts and types,
plus missing or invalid field names, without dumping guest payloads.
Late replies cannot pass after the readiness deadline. Unknown, missing,
malformed, or incomplete client state never passes because
a settle timer expired. The gate itself never reboots, deletes, rejoins, or
changes setup registry values. Failed retained-VM/Phase 0 preparation leaves
the existing lab intact. Fresh Phase 1 builds still follow normal failure
cleanup: use `New-Lab.ps1 -KeepFailedVMs` when investigating creation/setup
failures so the created VMs survive for diagnostics.
The legacy machine-OOBE wait cannot bypass this additional client gate.

Phase 2 adds read-only backstops before client rename and domain join, including
workgroup-client rename. Domain controllers and member servers pass immediately
after OS classification without client setup-registry or native OOBE checks;
intentional AAD OOBE, PXE/OSD, Linux, and migration preparation retain their
existing behavior. Domain-member rename verification reads the active registry
name, recognizes an already-staged pending rename, and requests a reboot only
after verifying the pending name. Failed or ignored rename writes fail explicitly.

Validate with `vmbuild\tools\Test-WindowsClientSetupReadiness.ps1` plus the existing
resume, OSD/PXE, and base-image staging regressions. The readiness regression uses
real background jobs to verify that the guest-command wrapper returns exactly one
result envelope, preserving client/server setup state and guest failure diagnostics.
The pinned main-to-develop candidate preflight runs this regression automatically
under both PowerShell engines; neither engine's result can substitute for the other.
OOBE repair qualification remains stricter: deployment readiness awaiting first
logon cannot substitute for full native OOBE completion and stability checks.
The shared helper ships as a loose `DSC\phases` script, not inside the module-only
`DSC.zip`. Deployment staging refreshes the whole DSC folder when its payload
signature changes; update the full folder rather than replacing only the ZIP.

### Windows setup failure diagnostics

A running VM and healthy Hyper-V heartbeat do not prove that Windows setup
completed. If a guest displays a setup failure page, use Shift+F10 to inspect
its setup state and Panther logs before attempting rename, domain repair, or
setup-registry changes.

When the guest console is unavailable, stop deployment/test retry loops and run
the following from an elevated PowerShell prompt on the VM's Hyper-V host:

```powershell
.\vmbuild\tools\Get-WindowsVmSetupDiagnostics.ps1 -VmName CST-W11CLIENT1 -AllowTurnOff
```

The collector targets one exact VM and holds the host mutation lease; an active
test/maintenance owner causes an immediate refusal. It requests graceful
shutdown for up to 90 seconds. `-AllowTurnOff` explicitly permits hard power-off
if shutdown fails or the VM is saved/paused; omit it to prohibit that fallback.
The VM is left **off**, not restarted. Only the VM's active disk paths are
mounted, read-only and without drive letters. Existing host mounts are refused.

Console screenshots are automatic. Before stopping a running/paused VM, the
collector captures its console through the Hyper-V framebuffer API using the
exact VM ID; it does not capture the host desktop or require guest credentials.
`Console-BeforeStop.png` and capture metadata are included in the protected ZIP.
Off/Saved VMs have no available live framebuffer and are explicitly recorded
as unavailable, not as successful screenshots. Blank/black frames are retained
as evidence; API or rendering failures make the evidence partial rather than
preventing the remaining setup-log collection.
Raw RGB565 and a four-byte big-endian total-length-prefixed provider layout are
supported. The latter is accepted only when the declared total exactly matches
the buffer and the remaining bytes exactly match the requested pixel dimensions.
Layout, source-byte count, and prefix size are recorded; black-frame detection
examines only pixels. Unknown/truncated/mismatched buffers remain explicit errors,
with dimensions and first/last DWORDs rather than blindly trimming extra bytes.
On decoding failures, buffers up to 16 MiB + 64 KiB are preserved unchanged as
`.rgb565.bin` with a `.rgb565.json` dimensions/error sidecar in the protected
evidence directory. These are diagnostic data, not successful screenshots.
The same bounded, resolution-capped capture helper is used by
`vmbuild\tools\Save-VmConsoleScreenshot.ps1`.

Collection and repair validate their Hyper-V, Storage, event-reader, and archive
modules/commands before shutdown, mounting, exports, or guest changes. A failed
dependency check leaves VM power and disks untouched and reports the original
load error. `-WhatIf` skips the explicit dependency preflight as well as VM changes.

If module loading names a missing `remoteIpMoProxy_*.format.ps1xml`, retry from a
fresh elevated Windows PowerShell 5.1 process rather than reusing the affected
PowerShell 7 session. From the repository root:

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File .\vmbuild\tools\Get-WindowsVmSetupDiagnostics.ps1 -VmName CST-W11CLIENT1
```

MemLabs retains missing CIM temp-parent recreation and stale-proxy reset.
When more than 200 shared `remoteIpMoProxy_*` directories accumulate, startup
reports the cleanup requirement but does not automatically delete them.
An old proxy may still be required by a live process. A clean process avoids
already-stale in-memory module references; recreating an empty directory does
not restore a missing format file.

Cleanup remains available as **explicit maintenance**. Stop deployments and
close other PowerShell-hosting applications, then start a fresh elevated
`powershell.exe -NoProfile` window directly, not from an existing PowerShell
session. From the repository root, preview before approving deletion:

```powershell
.\vmbuild\tools\Clear-CimProxyTempFolders.ps1 -WhatIf
.\vmbuild\tools\Clear-CimProxyTempFolders.ps1
```

Deletion requires the host mutation lease and refuses known other PowerShell/ISE/
remoting hosts, remoting sessions, or locally loaded proxy/CIM-producing modules
(including DHCP and Storage). These checks
do not identify every possible application embedding PowerShell; stopping those
applications is also a maintenance prerequisite. The existing >200-folder and
one-hour age safeguards remain. Only direct, non-reparse proxy directories with
both creation and last-write times older than one hour are eligible; activity
and directory eligibility are checked again before each deletion. Only flat
proxy folders are removed; nested directories or reparse contents require
manual inspection instead of recursive traversal.

When `-Destination` is omitted, its default is resolved from the tool's directory
after script parameter binding so fresh Windows PowerShell 5.1 `-File` launches
work correctly. An explicitly supplied destination is not replaced. Validate
this startup contract with `vmbuild\tools\Test-SetupDiagnosticDefaults.ps1`,
which also runs automatically in pinned-candidate preflight.

The protected archive path is printed under `vmbuild\logs\setup-diagnostics`
by default. It contains setup/domain-join logs (at most 20 MiB per file, retaining
the newest bytes and encoding marker when truncated), selected offline
setup/name/domain registry values, and a manifest of missing evidence/errors.
Setup, System, Application, DSC, user-profile, Winlogon, AppReadiness, AppX
deployment, Task Scheduler, CloudExperienceHost, Shell-Core, and AppModel
event summaries contain at most 80 selected records from the latest 1,000
records per log. Application summaries include profile and Winlogon failures.
Raw event XML is retained even when the host cannot format a guest event's message.
The collector checks both singular `User Profile Service` and legacy plural
`User Profiles Service` channel filenames. It also discovers existing OOBE,
authentication UI, profile/logon, AppX/AppModel, shell, device-registration,
modern/enterprise-deployment, AppLocker, and Code Integrity channels rather than
assuming every Windows build uses identical channel filenames.

`EventLogs` preserves the **full retained EVTX files**, independent of JSON
summary filtering and record limits. `Manifest.json` maps each short output name
to its original channel filename and records missing/read/copy outcomes.
Raw events are limited to 64 MiB per file, 256 MiB total, and 64 channels;
exceeding a limit is explicit partial evidence, never a silently truncated EVTX.
Security is not copied wholesale: `UserOobeSignIn-events.json` queries only
defaultuser0 and the configured local autologon account's sign-in success/failure
events (4624/4625), retaining up to 1,000
matching records. Hitting that limit is reported as partial. Empty results do
not prove that sign-in succeeded or that the guest had auditing enabled.

Existing Panther setup ETLs are retained whole up to 64 MiB each/128 MiB total.
CBS, DISM, and legacy userenv text logs are included when present, with the same
20 MiB text-log limit. Relevant FirstLogonAnim, OOBE, CloudExperienceHost,
Winlogon, msoobe, and WWAHost WER `Report.wer` files are collected from ReportArchive
and ReportQueue: at most 1 MiB per report, the newest 64 matching reports per
location, and 64 MiB total. Unrelated reports and WER memory dumps are excluded.
Disabled/unavailable channels cannot supply events retroactively; collection
does not enable tracing or restart Windows to manufacture missing evidence.
Volume-GUID paths are passed literally to the event reader. A query that
silently returns no records without an explicit empty-log status is reported
as missing/unverified evidence, not as a clean empty event log.
Bare volume-GUID roots are normalized to include their required trailing
backslash before native attribute checks; .NET Framework's `DirectoryInfo.Parent`
can omit it in Windows PowerShell 5.1.
Raw registry hives and unattend XML are excluded; private hive copies are
read using the system `offreg.dll` offline-registry library and removed after
inspection. No hive is mounted into the host registry. This supports OS hives
with different key security descriptors, which `RegLoadAppKey` does not.
Selected first-logon animation, autologon-progress, and user-OOBE settings are
also collected; Winlogon passwords and full unattend files remain excluded.
`AppxPrerequisiteInventory.json` adds read-only Runtime 2, Start Experiences, and
selected system OOBE/shell package-folder checks, manifest identities, and declared
framework dependencies. AppReadiness event 319 Runtime 2 package IDs are checked
against their exact expected manifest paths, retaining event timestamps so
inherited reference-image events can be distinguished from fresh failures.
Reads are limited to 64 matching folders per location, 1 MiB per manifest, and
128 dependencies per manifest; reparse points and XML DTDs are rejected.
Manifests are parsed from read-only file streams, so mounted volume-GUID paths
are not mistaken for XML source URIs.
Filesystem attributes distinguish missing paths from read errors on both
PowerShell engines while preserving the reparse-point refusal.
This inventory does not export manifests, per-user registration databases, or
user profiles, and it does not change packages or permissions. It is not a DISM
provisioned-package inventory or proof that a missing old version caused the
stall: a newer installed version can make an old preregistration entry stale.
Inventory read/parse failures are explicit partial evidence, while absent folders
and manifests are recorded as observations.
`FirstLogonConfiguration.json` adds SFAP profile/cache-file presence, size,
creation/modification times, owner/group SIDs, and DACLs. It records metadata
only (up to 32 profile directories/32 files each), never cache bytes. It also
extracts allowlisted `CopyProfile`, OOBE, local-account-name/group, and autologon
settings from available answer files; raw answer files, command lines, and
password values remain excluded. Oversize/malformed/DTD-bearing XML and
metadata-access failures are explicit partial evidence.

The offline registry allowlist includes the actual autologon SID,
`SystemAutoLogon`, shell/userinit, and selected LogonUI identity fields.
`WinlogonCredentialMetadata` uses a native **sizing-only** query for
`DefaultPassword` presence/type/byte length; it never reads that value's data.
Use a fresh PowerShell process after updating if an older native reader type
is already cached in the current process.

Security account lifecycle events for those scoped local accounts (4720/4722/4723/4724/4725/
4726/4738) are retained separately from its sign-in events. A filtered Winlogon
authentication summary retains event 1/2 history, including `Win32Status`,
independently of the general 80-record summary.
`FirstLogonFindings.json` builds a UTC timeline and flags interactive
defaultuser0 wrong-password audits (`4625`, substatus `C000006A`, logon type 2).
It temporally corroborates them with Winlogon result `1326` within five seconds.
Account-specific failure counts and corroborated account names are also recorded,
so a trial that signs in as the existing lab administrator does not hide its
authentication failures behind a defaultuser0-only filter. Unsafe/domain-qualified
autologon names are not interpolated into the XPath; the audit gap is reported
explicitly while defaultuser0 collection continues.
This is observed audit evidence, not password recovery, a live OOBE-ready
classification, or proof that an SFAP cache caused the failure. Missing/empty
audits do not establish healthy sign-in or enabled auditing.

The manifest identifies this implementation as `CollectorVersion=10` and
`RegistryReader=offreg.dll`.
An unavailable library or unreadable copy is reported as a collection error,
not proof of guest registry corruption. Console images and logs can contain
visible guest data or other sensitive details:
review the archive before sharing it. Partial or failed collections are
explicitly identified; unresolved disk-detach failures require manual cleanup
before restarting the VM. `-WhatIf` previews without stopping or mounting.

### Read-only collection directly from a VHDX

An exported/copied, detached OS disk can be inspected locally without importing
or booting its VM. In elevated PowerShell on a Windows machine with the Hyper-V
disk and Storage tools:

```powershell
.\tools\Get-WindowsVmSetupDiagnostics.ps1 -VhdxPath 'C:\Evidence\ADA-W11CLIENT1_OS.vhdx'
```

Extract a ZIP first and point at the actual `.vhdx` (or active `.avhdx`, with
its complete parent chain available). This mode is mutually exclusive with
`-VmName`, live probes, hang dumps, repair, guest credentials, and power options.
It does not invoke VM inventory/power/console operations or load guest credentials.
The disk is mounted **read-only, without drive letters**, using the same evidence
pipeline as VM collection. Already attached disks are refused rather than
borrowed, stopped, or detached. Only the owned mount is dismounted, and final
state is reported as `Detached`; an unverified detach is explicit failure.
`-Destination` and `-WhatIf` remain available.

Offline inspection cannot reconstruct a stopped process's memory or validate
Windows first-boot authentication/readiness. The guided image comparison still
requires fresh generalized copies and actual VM boots; changing an already-failed
disk offline would not by itself establish prevention or recovery.

Validate the collector's mocked Hyper-V/storage safety contracts with
`vmbuild\tools\Test-WindowsVmSetupDiagnostics.ps1`. It also exercises disposable
uniform/mixed-security hive fixtures and isolated mutex contention; it does not operate
on real VMs or load host registry hives.
Package inventory is also tested through real local volume-GUID aliases of
disposable fixture files, including the production collection/archive path.
Validate framebuffer conversion, exact VM targeting, unavailable/black-frame
handling, and capture-error reporting with `vmbuild\tools\Test-VmConsoleScreenshot.ps1`.

### Optional read-only live first-logon probe

For an intact Windows client stalled at first sign-in, add `-IncludeLiveProbe`
to the same collector command:

```powershell
.\tools\Get-WindowsVmSetupDiagnostics.ps1 -VmName ADA-W11CLIENT1 -IncludeLiveProbe
```

The default remains offline-only. The opt-in mode accepts **Off or Running**
VMs, starts only the exact selected Off VM, allows 190 seconds of normal
first-logon progress, then performs bounded PowerShell Direct queries.
It automatically uses the saved MemLabs administrator credential; an explicit
`-GuestCredential` still overrides it. `-WhatIf` never loads credentials or
starts the VM. Saved/Paused VMs must first be resumed or shut down normally;
`-AllowTurnOff` does not bypass this live-probe precondition.

`Live-StateBefore.json`, `Live-Appx.json`, and `Live-StateAfter.json` record
machine/native OOBE state, scoped first-logon service states,
selected process/session/owner SIDs and FirstLogonAnim
thread wait reasons, registered package status and per-user install states,
and scoped provisioned-package identities/manifest presence.
Package-user identities use the AppX object's SID field rather than its type-name
string representation; unreadable/invalid SIDs make the evidence explicitly partial.
Package scopes include Windows App Runtime, VCLibs, XAML, OOBE, CloudExperienceHost, CBS,
Start Menu, Shell Experience Host, and Start Experiences. Bundle manifests are
checked at their bundle-specific path. No process command lines, memory dumps,
passwords, user-profile contents, or raw registration databases are collected.

Each guest query has a 60-second deadline and is never retried with alternate
credentials. PowerShell Direct authentication, transport, and timeout failures
stop further live queries and make the evidence partial; normal graceful shutdown
and offline collection then continue. A failed or unverified VM startup instead
stops further power/disk actions and reports failed/indeterminate evidence for
manual inspection.
The normal collector shutdown/mount safety rules still apply and the VM is
left Off when shutdown succeeds.
Individual package/service/process read errors are retained explicitly while
independent data can still be collected; they never become clean empty results.

This is inspection, **not repair or proof of recovery**: it does not change
AppX registration, policies, setup-completion flags, computer names, or domain
membership. Windows can naturally progress during the explicitly requested
boot/observation period. Validate the guest scopes and bounded host orchestration
with `vmbuild\tools\Test-WindowsVmFirstLogonProbe.ps1`, plus the existing collector
and startup-default regression scripts, on both PowerShell engines.
If the setup-state query fails before it can determine the client type, the
snapshot preserves its actual `ProbeFailed` diagnostics as explicit partial,
not-ready evidence. It does not relabel an unknown type as a server or relax
the deployment readiness gate.

### Optional FirstLogonAnim hang dump

While the existing VM is **Running and still displaying "Just a moment"**, run:

```powershell
.\tools\Get-WindowsVmSetupDiagnostics.ps1 -VmName ADA-W11CLIENT1 -IncludeLiveProbe -IncludeHangDump
```

`-IncludeHangDump` is explicit and cannot be combined with `-RepairOobe`.
It requires an already Running VM even when `-IncludeLiveProbe` is also present:
it never starts/resumes/restarts a stopped VM to obtain a dump. The normal
offline-only command remains usable when the VM is Off, but cannot reconstruct
the memory of a process that stopped at shutdown.

The collector captures a console image, then dumps only the unique
`System32\oobe\FirstLogonAnim.exe` process before live queries or shutdown.
PID, executable path, and process start time are checked again against the
native process handle, preventing PID reuse from selecting another process.
A separate guest writer uses the system DbgHelp API with full process memory,
handles, unloaded modules, and thread metadata. No external dump tool is
downloaded, and no Winlogon, LSASS, or whole-VM dump is taken.
Capture can briefly affect the target process; it is diagnostic work, not a
strictly passive query or a repair.

The writer is limited to 120 seconds and has its own watchdog. Only its owned
capture process may be stopped on timeout, never FirstLogonAnim. The host RPC
has a 180-second deadline with no authentication retry. An unverified outcome
leaves the VM running and aborts shutdown/mounting rather than destroying the
wait state. Known capture failures are explicit partial evidence.

Successful capture continues through the usual graceful shutdown/read-only
mount. The collector verifies the MDMP header and rejects files over 512 MiB,
then copies and checks the captured length/SHA-256 before including
`FirstLogonAnim.dmp` in the protected ZIP. The protected guest artifact remains
at `C:\ProgramData\MemLabsSetupDiagnostics-<token>\FirstLogonAnim-<pid>.dmp`;
its path is recorded for later operator cleanup. The offline mount is never
made writable to remove it. Owned writer scripts and output files are cleaned
up when the writer is confirmed stopped.

Process memory can contain sensitive data even in a lab; review/protect the
dump before sharing. Validate native-payload compilation, target restrictions,
deadline/unknown-outcome behavior, and verified offline transfer using
`vmbuild\tools\Test-WindowsVmFirstLogonDump.ps1` on both PowerShell engines.

### Building and qualifying Windows client base images

`vmbuild\baseimagestaging\New-BaseImage.ps1` requires a fresh disposable
first-boot qualification for Windows 10/11 client images after successful
offline Sysprep verification and **before** copying/promoting the golden image.
The installed OS's read-only registry metadata determines whether this check is
required; a custom WIM filename cannot bypass it.
Sysprep tags, shutdown, disk integrity, and hashes alone do not qualify OOBE.

The generalized source stays untouched. Qualification boots one independent,
hash-verified clone using the staging VM's hardware/switch and saved local
administrator credential. It allows Windows-owned setup restarts, waits an
additional six minutes plus the collector's observation window, and requires
both read-only snapshots to pass the existing unattended deployment readiness
checks. Only the passive settling interval permits normal Off/Starting/Stopping
transitions; the same VM must be Running at its end. Live collection remains
strict about the target staying Running. The measured settling duration is saved
in the qualification report. No completion flags, passwords, cache contents, rename, or domain-join
settings are changed. Failure prevents capture/promotion and preserves the
staging VM and diagnostic evidence; it does not replace the prior golden image.

`-OutputDirectory` selects a separate candidate directory instead of the
published OS cache. `-SkipHostPreparation` avoids unrelated host preparation
and maintenance refresh on an already prepared host. Use a new WIM basename
or the explicit clean-rebuild switches rather than reusing a failed deployment
disk or resuming an old customization VM.
Keep comparison `-Destination` paths short: Hyper-V configuration paths must be
below 260 characters. Overlong destinations are rejected before image copying
or VM creation rather than failing later while creating the Smart Paging store.

`-EnableFirstBootAutoLogon` is an **opt-in lab-image setting** for clients that
need a real first administrator sign-in to finish OOBE. After final Sysprep it
configures only the owned staging VM disk, reusing the existing local lab
administrator's answer-file password element without decoding or exporting it.
The first-logon command sets `AutoLogonCount=0` and `AutoAdminLogon=0`; it does not
set OOBE completion flags or bypass setup. This includes Microsoft's documented
[single-logon workaround](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-autologon-logoncount)
for the positive `LogonCount` off-by-one issue. Existing first-logon commands and
other answer-file settings are preserved. This option is not enabled by default,
does not apply to servers, and refuses disks outside the owned staging VM path.
Its staging marker also makes the existing host/DSC readiness gate wait until
cleanup is verified, preventing rename/domain join from racing that first-logon
command. Images without the marker retain their existing readiness behavior.
This is not a disk-format migration: existing supported Windows 10/11 VHDX
images do not need conversion or new metadata, and Windows Server remains
excluded from the client-only gate.

With this option, qualification additionally requires native OOBE completion
in both snapshots, an interactive desktop owned by the lab administrator, and
readable offline evidence that both autologon values are zero. A ready state
awaiting first logon, partial collection, or still-enabled autologon cannot
qualify this candidate. Use `-OutputDirectory` to retain it separately until a
full deployment smoke test is complete; no rolling `Latest` mapping is changed.

A qualified Windows client artifact gets a `.qualification.json` receipt with
its SHA-256, qualification time, and diagnostic archive. The copied artifact is
checked against the qualified source hash before promotion. The hash marker and
receipt are staged before replacing any existing artifact; a publication failure
rolls back the image and both metadata files together. Two ready snapshots are
required, not a continuously monitored readiness interval. A first-boot pass
is not a substitute for a full single-client deployment validation before
changing a rolling `Latest` image mapping. The receipt also records whether
bounded first-boot sign-in was enabled and its cleanup/OOBE completion verified.

The single-clone check is also available through
`Test-WindowsFirstLogonImage.ps1 -TestVariant FirstBootQualification`.
Existing SFAP and explicit-autologon comparison variants retain their defaults.
Windows Server offline Sysprep checks and the separate Linux builder are unchanged.

### Guided, disposable first-logon image comparison

Use this when investigating whether per-user SFAP credential-cache state carried
through `CopyProfile` contributes to a fresh Windows 11 first-logon stall.
This is an experiment, **not a production image fix or a readiness bypass**.

Stop deployment/test retry loops. In elevated PowerShell on the lab's Hyper-V
host, run:

```powershell
Set-Location E:\memlabs\vmbuild
.\tools\Test-WindowsFirstLogonImage.ps1 -VmName ADA-W11CLIENT1
```

No guest-console commands, manual registry changes, or manual VHDX edits are
needed. The selected existing VM is only a reference for the cached OS identity,
memory/CPU, secure boot/TPM, and existing virtual switch. Its power state,
configuration, and disks are not changed.

The tool:

1. Finds the OS-ID match in the locally cached file lists under `azureFiles`
   (or an already loaded `Common.AzureFilesPath`). If there is no unique match,
   it presents available Windows 11 images for a simple numbered selection.
   An explicit `-SourceVhdxPath` is available when the image lives elsewhere.
2. Inspects the chosen source **read-only** and rejects attached/differencing
   disks, completed/failed VM OS disks, non-Windows-11 images, missing
   `CopyProfile`, and answer files requesting a domain join. A fresh generalized
   base image is required: cold-booting an already-failed VM would confound
   this comparison.
3. Makes and hash-verifies two independent VHDX copies. Both receive matched
   offline inspection/mounting. The control keeps its SFAP state. Only the
   disposable test copy has known `cache0.bin`/`cache1.bin` files and their empty
   SFAP directories removed from its local profiles. Unexpected files, reparse
   points, or path mismatches stop the test instead of broadening deletion.
4. Creates fresh `ML-OOBE-C-*` and `ML-OOBE-T-*` VMs with new identities, runs
   them **one at a time**, and invokes the existing live/offline diagnostic
   collector automatically with saved MemLabs credentials.
5. Saves `FirstLogonComparison.zip` containing a comparison report and the two
   diagnostic ZIPs, **not** the large VHDX copies. The source hash is checked
   again before reporting completion.

The trial VMs use the reference VM's existing lab virtual switch; they are
isolated **copies**, not a separate isolated network. New adapters receive new
MAC addresses. The guided path requires one untagged adapter and does not
guess special VLAN/network settings. No MemLabs DSC, computer rename, or
domain-join phases run.

Allow twice the base VHDX file size plus 2 GiB of free space, and time for two
fresh Windows boots, image copies/hashes, and diagnostic collection. Progress
steps and operation limits are printed. The default workspace is a protected
`FirstLogonComparisons` sibling directory beside the original VM; `-Destination`
can select another local drive.

After evidence and final Off state are verified, the tool removes only its own
tagged trial VMs and disks. `-KeepTrialVMs` retains them Off for further inspection.
Unknown startup/operation outcomes or failed ownership checks stop the comparison
and preserve unverified resources at their reported paths. The original VM and
golden image are never cleanup targets. `-WhatIf` performs no credential loading,
mounting, copying, startup, or removal.

A cleaned copy becoming ready while the control reproduces the specific
FirstLogonAnim stall supports the cache hypothesis **in that trial only**.
Both ready means the original failure was not reproduced; both stalled means
cache removal alone did not resolve it. Other/unreadable/transitioning setup
states are inconclusive. Review the supplied diagnostics before adopting any
image-preparation change.

#### Explicit local-account sign-in variant

If the cache comparison reproduces the same temporary-account authentication
failure in both arms, test Windows-supported unattended sign-in using the
image's existing local lab-administrator account:

```powershell
.\tools\Test-WindowsFirstLogonImage.ps1 -VmName ADA-W11CLIENT1 -TestVariant ExplicitAutoLogon
```

The default `SfapCache` experiment is unchanged. `ExplicitAutoLogon` leaves
**CopyProfile and all SFAP caches untouched** in both arms. It changes only the
disposable test copy's existing `oobeSystem` Shell-Setup components by adding
`AutoLogon` for the local administrator whose name matches the saved lab
credential. No account password is reset.

The password XML element is reused from the same image's matching local-account
configuration, preferring the staging answer file when the cached Panther copy
has scrubbed sensitive data. It is not decoded, printed, or put in the report.
Missing/ambiguous accounts, non-administrator groups, unusable password elements,
namespace mismatches, and pre-existing oobeSystem autologon are rejected before
any answer file is changed. Only the exact owned test VHDX is writable; source
and control files remain unchanged, and both written answer files are read back.

The test requests `LogonCount=1`. Microsoft documents an off-by-one issue where
positive counts can allow one additional sign-in; this tool performs only its
single trial startup and does not add a registry-bypass first-logon command.
These settings are **temporary experiment data, not a production image change**.
If `-KeepTrialVMs` is used or a failure requires retention, keep the disposable
test copy protected: it contains administrator autologon configuration.

Readiness alone is not called a verified explicit-sign-in success. The report
also checks the effective autologon username and an interactive Explorer shell
owned by the lab account in both live snapshots. Missing confirmation is
inconclusive. Even a positive comparison supports an alternate sign-in path
only for that trial; it does not explain why Windows supplied the wrong
temporary-account credential or prove a permanent fix.

Run `vmbuild\tools\Test-WindowsFirstLogonImageComparison.ps1` on PowerShell 5.1
and 7 to validate discovery, source/copy safeguards, matched create/cleanup
contracts, sequential execution, verdicts, and real cold-start parameter binding
using synthetic files and mocked VM operations.

### Explicit OOBE-only recovery trial

Repair is **not** the normal deployment strategy. The client setup gates above
prevent rename/domain join from starting before Windows Welcome is complete.
For an already-stranded client, the collector additionally exposes an explicit
`-RepairOobe` trial. Ordinary collection remains read-only.

Run on the Hyper-V host, from the repository root in elevated PowerShell, with
deployment/test retry loops stopped:

```powershell
.\vmbuild\tools\Get-WindowsVmSetupDiagnostics.ps1 -VmName CST-W11CLIENT1 -RepairOobe
```

If the selected VM is Saved or Paused, repair does not start and no disk is
mounted unless `-AllowTurnOff` is explicitly supplied. That initial power-off
discards saved memory state; review that consequence before opting in:

```powershell
.\vmbuild\tools\Get-WindowsVmSetupDiagnostics.ps1 -VmName CST-W11CLIENT1 -RepairOobe -AllowTurnOff
```

This permission does not change the later verification reboot cycles, which
still require graceful shutdown.

Credentials are automatic: the tool reuses an already-loaded `Common.LocalAdmin`
or calls the main script's `Get-LocalAdminCredential` helper against the same
`vmbuild\cache\vmbuildadmin.txt` cache. This does not initialize storage,
maintenance, or host settings and does not download credentials. If the saved
credential is missing or empty, the tool stops before guest operations; initialize
credentials using the main script, or provide an explicit `-GuestCredential`
override. Credentials are never included in the repair report.

**A VM backup is optional and is skipped by default.** Without `-BackupPath`, the
confirmation and warning identify that a failed trial may require rebuilding
the client; the report records `BackupRequested=false` and `BackupVerified=false`.
Offline before/after evidence and restoration of temporary settings still apply.

To request a backup, add `-BackupPath 'E:\VMBackups'`. Use a location outside the
VM's configuration/disk directories with enough space for a complete export.
The tool then validates the stopped VM export, configuration/disks and
self-contained parent chains, and restricts the backup ACLs before starting the
selected VM. **The full export contains guest data and must not be shared as a
diagnostic archive.** A requested but unverified backup still blocks repair.

The trial supports the post-setup OOBE failure pattern, not arbitrary Windows
damage. It stops if PowerShell Direct cannot authenticate with the supplied
credential or cannot obtain an elevated, readable Windows-client state.
It temporarily removes only the three known lab Windows Update blocking
values when they are DWORD `1`, and enables/starts `wuauserv` if necessary.
If no known blocker exists, it refuses speculative repair. It never forces
setup-completion flags, resets ACLs, re-registers apps, renames the computer,
resets its machine password, or unjoins/rejoins the domain.

If instructed while the script waits, click **Next** on the failure page in
VMConnect so Windows can retry; no console command block needs pasting.
The default native-OOBE completion window is 15 minutes
(`-RepairTimeoutSeconds`, 60–3600 seconds). After completion, the script restores
the original policy/service configuration and verifies **two graceful reboot
cycles**, each with at least **190 seconds** of stable native/setup/name state.
It also confirms the shutdown hive state is complete. Verification never
uses forced power-off.

A successful result is `OobeRecoveredIdentityUnchanged`, not a claim that AD
identity or the whole deployment is repaired. Before/after diagnostics,
original settings, backup location, and stage outcomes are written to a
protected report ZIP; credentials and the VM export are excluded.
Repair captures additional console images after startup, after OOBE completion,
after each verified reboot, and on failure before any safe final shutdown.
`EvidenceStatus=Partial` identifies screenshot failures separately from the
recovery outcome. No screenshot failure silently turns into clean evidence.
Known failures restore settings where safe and leave the VM off when graceful
shutdown succeeds. A timed-out remote action or failed restoration is
`Indeterminate`: the VM may remain running, and the script does **not** blindly
retry, reboot, or overwrite later policy changes. Inspect
the original-settings receipt before taking further action. Retain any backup
that was requested.

Validate with `vmbuild\tools\Test-WindowsOobeRecovery.ps1`. It uses mocked
Hyper-V/guest operations and disposable files; live recovery viability must
still be confirmed on the affected host.

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
The receipt contains exactly one structured result per target. Per-target console
logging is emitted separately by the host monitor, so log objects cannot become
false certificate failures. Missing, malformed, or failed probe responses still
fail closed, and transport errors remain visible in the per-target diagnostics.
Successful receipts must contain Boolean success/readiness fields and complete,
unique coverage of the requested target set. Request publication and receipt
commit use the same state lock and atomic JSON writer; a replaced request cannot
overwrite a newer receipt and is reported as superseded rather than failing the
replacement workflow. Native enrollment invocation failures and unreadable event
logs remain diagnostic evidence. Chain URL retrieval is limited to ten seconds,
and a cryptographic error on one candidate does not hide another usable certificate.
The existing certificate validity/private-key/trust policy and lab revocation
behavior are unchanged. Validate with `vmbuild\tools\Test-PkiClientPrestage.ps1`
and `vmbuild\tools\Test-PkiPrestageState.ps1`.

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

## Reporting Point and SUP resource readiness

A running reporting service is not sufficient for Phase 8: its ReportServer
endpoint must also respond. When an RP/SUP host reports HTTP 503 after WSUS
out-of-memory errors, check its assigned memory and demand in the Phase 8
timeline before retrying; passing DNS, RPC, SMB, and WinRM checks does not
establish reporting-service health.

The CSTest3 existing-VM mutation explicitly brings the CAS RP/SUP host to the
current baseline's 8 GB allocation. Both DP/MP/SUP hosts use 8 GB each, and the
file server uses 3 GB; SQL, site-server, and client allocations are unchanged.
The complete 13-VM fixture budget is 70 GB, with an additional 8 GB host reserve
included in the planner's 78 GB requirement, within the available 100 GB budget.

Older main-built VM Notes can still specify 3 GB for the RP/SUP host, and prior
reduced-memory configs may leave other VMs below their current allocations.
Changing fresh-build fixtures alone does not update those Notes, so the mutation
also includes memory-only updates for the existing RP/SUP host, added DP/MP/SUP
host, and file server. Regenerate previously materialized mutation configs to
include these changes. Phase 0 applies the resizes and restarts affected VMs;
rerunning from Phase 3 then includes PBIRS verification in Phase 7 before
ConfigMgr role setup.

Role-target diagnostics read reporting-service logs from both MemLabs' configured
PBIRS install directory and the default Program Files location, limiting each
pattern to its two newest files. Failure-log manifests explicitly convert typed
artifact lists to arrays so PowerShell's collection binder cannot discard the
baseline evidence with `Argument types do not match`.

Validate with
[`Test-ExistingVmMutationMaterializer.ps1`](vmbuild/tools/Test-ExistingVmMutationMaterializer.ps1),
[`Test-CmRolePhysicalReadiness.ps1`](vmbuild/tools/Test-CmRolePhysicalReadiness.ps1),
and [`Test-CmFailureDiagnostics.ps1`](vmbuild/tools/Test-CmFailureDiagnostics.ps1).

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
