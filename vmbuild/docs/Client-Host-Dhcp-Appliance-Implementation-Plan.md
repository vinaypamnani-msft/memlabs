# Windows Client Host DHCP Appliance Implementation Plan

## Decision summary

MemLabs should select a DHCP backend from host capabilities:

- **Windows Server host:** keep the existing local Windows DHCP Server backend unchanged.
- **Windows Client host:** use one or more MemLabs-owned Ubuntu `dnsmasq` appliance VMs.
- **Explicit override:** support an opt-in backend override during development and troubleshooting, but reject an unsupported combination rather than silently falling back.

A fresh Client host should **not create an appliance merely because MemLabs opened**. At that point there may be no selected deployment and therefore no lab switches or scopes to serve.

The lifecycle should be:

1. On every MemLabs startup, detect and record the host/backend capability.
2. If no managed lab networks exist, defer appliance creation.
3. On the first deployment, after the configuration is validated and its network set is known, download/verify the appliance image, create the switches/NATs, create the appliance, apply DHCP desired state, and prove it healthy **before Phase 1 starts any VM**.
4. On later deployments, reconcile the appliance after configuration selection and validation, before any deployment phase can start a VM. Missing or provably corrupt appliances are rebuilt from deployment configuration, MemLabs VM notes, and live Hyper-V topology. GenConfig startup remains read-only with respect to live VMs.

“Automatic rebuild” initially means **at the next deployment and at every pre-Phase-1 health gate**. The first version should not run a background task that autonomously deletes and recreates VMs; destructive recovery must run in the foreground with full ownership proof and diagnostics.

## Why not install Windows DHCP Server on Client

Windows Client does not expose the Windows Server DHCP role or `Install-WindowsFeature`. Copying Server role binaries onto Client would be unsupported, would bypass servicing, and would leave MemLabs dependent on an unmaintainable host mutation.

The appliance approach keeps the host supported and preserves DHCP/PXE behavior. An all-static mode is not sufficient because OSD/PXE clients still require DHCP.

## Required invariants

1. The existing Windows Server path does not change behavior.
2. DHCP desired state is reconstructible from deployment configuration, MemLabs VM notes, and live Hyper-V topology; the appliance is never its only authority.
3. Deleting the appliance VM must not delete the desired scopes/reservations.
4. A missing appliance is rebuilt only when its MemLabs ownership is proven.
5. A name collision with a non-MemLabs VM is a hard failure, never an automatic deletion.
6. The appliance must be healthy before Phase 1, PXE, or relay validation proceeds.
7. Every scope is served by exactly one backend/appliance.
8. No appliance binds to an external/default switch or provides DNS/TFTP/proxy-DHCP.
9. State updates and guest configuration replacement are atomic and validated before activation.
10. Unknown state is reported as unknown and blocks destructive recovery; it is never interpreted as absent or corrupt.

## Architecture

### Host capability and backend selection

Add a pure capability probe, tentatively `Get-MemLabsHostNetworkBackend`:

- Query `Win32_OperatingSystem.ProductType` (`1` is Client).
- Verify Hyper-V service and cmdlets independently.
- Detect the local DHCP Server service/module independently.
- Return structured evidence: host type, Hyper-V availability, native DHCP availability, selected backend, and reason.

Selection rules:

| Host state | Backend/result |
| --- | --- |
| Server + usable DHCP role | `WindowsDhcp` |
| Client + usable Hyper-V | `DnsmasqAppliance` |
| Client without Hyper-V | Fail with Client Hyper-V prerequisite |
| Server with broken/missing DHCP role | Fail and repair native role; do not silently switch |
| Explicit development override | Honor only after capability validation |

Store the result on `$Common.DhcpBackend`. `Install-HyperV` must branch before calling Server-only cmdlets. On Client it should verify or enable the Client Hyper-V optional feature and never call `Get-WindowsFeature`/`Install-WindowsFeature`.

### Appliance topology

Use host-wide appliances rather than one appliance per deployment. A single VM cannot be assumed to serve unlimited networks: the existing relay implementation already enforces an eight-adapter safety limit.

- Names: `MemLabs-DHCP-01`, `MemLabs-DHCP-02`, ...
- Generation 2 Ubuntu cloud image.
- Static memory, initially 1 GB; reduce it only after first-boot/cloud-init stress testing proves a lower floor reliable.
- One synthetic NIC per served lab switch; maximum eight NICs per appliance.
- No separate management NIC is required. The host can reach the appliance directly through each internal switch.
- Each served subnet assigns the appliance `<subnet>.19`, below the dynamic pool (`.20-.199`) and outside existing fixed-role addresses.
- Exactly one appliance owns a scope.
- Stable scope-to-appliance assignment is recorded in each appliance VM note. Existing assignments are retained; new scopes fill the first shard with capacity. If an appliance is gone, its scopes are safely assignable again because assignment is placement metadata, not DHCP authority.

Before reserving `.19`, reconciliation must prove it is unused by current MemLabs VMs, Hyper-V-reported guest addresses, and persisted reservations. A conflict is fatal and named; do not silently choose another address.

### Appliance image

The appliance must be bootstrappable with no DHCP:

- Reuse the verified Ubuntu Server cloud VHDX initially.
- Make the image a required download whenever `DnsmasqAppliance` is selected, even if the user configuration contains no Linux VM.
- Generate a dedicated multi-NIC NoCloud network configuration keyed by NIC MAC address.
- Give every NIC its `.19/24` address; only one NIC receives a default route through `.200`.
- The current baked image already includes `dnsmasq-base`; cloud-init should still verify/install it as an idempotent fallback. Static networking plus host NAT allows that fallback without DHCP.
- Authorize the existing MemLabs Linux host SSH key. Do not store new secrets in appliance VM notes.

A dedicated versioned appliance artifact can replace the generic Ubuntu image later, but it is not required for the first implementation.

### Provider boundary

Introduce a provider API rather than allowing new direct `DhcpServer` cmdlet calls. Candidate operations:

- `Get-MemLabsDhcpBackend`
- `Initialize-MemLabsDhcpBackend`
- `Get-MemLabsDhcpDesiredState`
- `Sync-MemLabsDhcpDesiredState`
- `Get-MemLabsDhcpScope`
- `Get-MemLabsDhcpScopeStatistics`
- `Get-MemLabsDhcpReservation`
- `Get-MemLabsDhcpLease`
- `Get-MemLabsDhcpFreeAddress`
- `Add-MemLabsDhcpReservation`
- `Remove-MemLabsDhcpReservation`
- `Add-MemLabsDhcpExclusion`
- `Remove-MemLabsDhcpExclusion`
- `Remove-MemLabsDhcpScope`
- `Get-MemLabsDhcpDiagnostics`

The Windows backend delegates to the existing DHCP cmdlets. The appliance backend updates the canonical desired state and reconciles it atomically. A repository gate should reject direct DHCP cmdlet calls outside the two backend implementations and explicitly approved test/diagnostic files.

### Reconstructible source of truth

Do **not** add a separate host-side DHCP state file. It would duplicate VM-note data, introduce a split-brain case when the file and Hyper-V disagree, and create another artifact whose loss or partial update needs recovery.

Each reconciliation compiles complete desired state from:

1. The current deployment configuration, including VMs not created yet.
2. Live Hyper-V VM topology: VM IDs, NIC MACs, switch attachment, and guest/KVP addresses.
3. Existing MemLabs VM notes: domain, role, network, `AssignedIP`, `LastKnownIP`, and ownership provenance.
4. Hyper-V internal-switch names/notes and the fixed MemLabs network contracts.
5. Surviving DHCP appliance VM notes, used only to preserve stable shard placement and record applied-version evidence.

The appliance VM note should be schema-versioned and contain only infrastructure identity and placement metadata:

- `infrastructureType = MemLabsDhcpAppliance`
- `schemaVersion`
- `applianceVersion`
- `shardNumber`
- `ownedScopeIds[]`
- `appliedConfigHash`
- `sourceImageHash`
- `lastSuccessfulReconcileUtc`

It must not contain credentials, private keys, or the only copy of any scope or reservation. If an appliance VM is destroyed, its note disappears too; that is safe because all DHCP semantics are reconstructed from the surviving lab VMs and the selected deployment. Surviving appliance notes preserve their assignments, and unassigned scopes fill available shards deterministically.

A scope is desired only when the current deployment or at least one live MemLabs-owned VM references it. A leftover switch alone is insufficient to resurrect DHCP for a removed lab.

### Reconstructing scopes and reservations

For each scope:

- Router: `<subnet>.200`, except the legacy Cluster scope which intentionally has no DHCP options.
- Pool: `<subnet>.20` through `<subnet>.199`.
- Domain scope DNS/WINS: the domain DC address, normally `<DC network>.1`.
- Internet scope: public DNS and no domain option, matching current behavior.
- Lease duration: 365 days, matching current behavior.

Reservation evidence precedence:

1. `AssignedIP` persisted in a MemLabs VM note.
2. `LastKnownIP` persisted in the note.
3. A single in-subnet address reported by the live Hyper-V adapter/KVP.
4. A role-fixed address only for roles whose address contract is already explicit.
5. Otherwise: no invented reservation; report the VM as dynamic/unknown and let it acquire from the pool.

Every candidate must be checked for duplicate IPs, duplicate MACs, wrong subnet, multiple domain owners, and conflicts with `.19`/`.200`/fixed infrastructure addresses. Ambiguity blocks apply.

Dynamic leases do not need durable replication. Managed non-OSD VMs have deterministic reservations reconstructed from their notes; transient clients such as OSD VMs may reacquire a lease after appliance replacement. Losing an active dynamic lease is acceptable, but losing a provable reservation is not.

## Startup and deployment sequences

### Fresh Client host, MemLabs opened without deploying

1. Initialize Common.
2. Detect Client + Hyper-V and select `DnsmasqAppliance`.
3. Scan for existing MemLabs-owned lab VMs/networks.
4. If none exist, log that appliance creation is deferred.
5. Open GenConfig/menu normally.

No appliance, switch, image download, or background VM is created merely by opening MemLabs.

### First deployment on a Client host

1. Load and validate the selected configuration.
2. Build desired network/scope state from the deployment.
3. Download and hash-verify the Ubuntu appliance image.
4. Create/verify internal switches, host `.200` addresses, forwarding, and NAT **without calling native DHCP**.
5. Create the required appliance shard(s), attach NICs, and generate MAC-bound static cloud-init networking.
6. Boot and wait for SSH using `.19`; no DHCP is involved in appliance bootstrap.
7. Render the complete `dnsmasq` configuration.
8. Run `dnsmasq --test` against the temporary configuration.
9. Atomically activate it, restart/reload the service, and verify service state, UDP/67 listeners, interfaces, addresses, and config hash.
10. Only after that gate succeeds, run IP preallocation/reservation creation and Phase 1.

### Later deployment with existing labs

After the deployment configuration is selected and validated, before deployment work may start VMs:

1. Rebuild desired state from live VM notes/topology and surviving appliance placement notes.
2. Inspect every expected appliance.
3. Reapply drifted networking/configuration or start a stopped healthy appliance.
4. Rebuild a missing/provably unusable appliance.
5. Stop startup if DHCP cannot be restored; do not proceed into VM starts that will predictably fail.

### New deployment added to an existing Client host

Merge the new deployment with all existing owned scopes. Never render only the selected deployment, because doing so would remove DHCP for other labs on the host.

Add new scope NICs to existing shards with capacity. Configure the guest interface by MAC, update desired state atomically, validate, then continue.

## Reconciliation state machine

| Observed state | Action |
| --- | --- |
| No managed scopes | No appliance needed; optionally remove an empty appliance only during explicit cleanup |
| Appliance absent, desired scopes present | Create from immutable base image, apply all desired state, validate |
| Appliance stopped, disk/config identity valid | Start, validate, then reconcile configuration |
| SSH works, service stopped | Repair/restart service and validate |
| SSH works, config hash differs | Apply validated atomic config and reload |
| Adapter/address drift | Repair by MAC, then validate; rebuild only if repair cannot establish a safe topology |
| OS disk absent/unreadable or SSH never becomes ready | Capture diagnostics, prove ownership, rebuild from base image |
| VM name occupied without valid MemLabs infrastructure identity | Fail; never delete or modify it |
| Appliance note missing/unreadable | Treat placement as unknown, reconstruct DHCP semantics from lab VM notes/current config, and assign the scope to a proven owned appliance |
| Desired state has conflicts/unknown ownership | Fail before changing the running DHCP configuration |

A service/config repair should always be attempted before VM replacement. Destructive replacement requires both the reserved name and a valid MemLabs infrastructure identity marker (VM ID/note/schema). The rule should mirror `Test-VmPhase1Incomplete`: absence of proof is not permission to delete.

## Guest `dnsmasq` configuration

Use a dedicated service and config, not the distribution-wide generic `dnsmasq.service`:

- `memlabs-dhcp.service`
- `/etc/memlabs-dhcp.conf`
- `/var/lib/memlabs-dhcp/dnsmasq.leases`

Required behavior:

- `port=0` so the appliance does not provide DNS.
- Bind only to MAC-resolved interfaces attached to desired MemLabs switches.
- Authoritative DHCP for each owned scope.
- Dynamic range `.20-.199` plus `dhcp-host` entries for reservations.
- Scope-specific router, DNS, domain, WINS, and lease options matching the Windows backend.
- No TFTP, boot filename, next-server, or proxy-DHCP configuration. ConfigMgr PXE responder retains ports 69/4011 and PXE policy ownership.
- Firewall allows DHCP only on desired interfaces and SSH from the host-side `.200` addresses.
- systemd restarts the service on process failure.

The apply script must:

1. Decode the complete desired payload into a unique temporary file.
2. Reject malformed or empty-when-scopes-expected payloads.
3. Run `dnsmasq --test`.
4. Atomically replace the live file.
5. reload/restart the service.
6. Verify every expected listener/interface/address and emit a machine-readable result.

## Removal and cleanup integration

The appliance is infrastructure, not a normal lab VM:

- Exclude it from `Get-List` user VM inventory, normal maintenance, connection files, domain operations, and orphan prompts.
- Domain removal first removes that domain’s scopes from desired state and detaches them from appliances, then evaluates whether switches/NATs are still in use.
- Appliance NICs must not make an otherwise unused domain switch appear user-owned forever.
- `Remove-Lab -All` may remove appliance VMs only after all managed scopes are gone.
- Removing one domain must not stop or rewrite unrelated scopes incorrectly.

## Failure semantics and diagnostics

- Backend initialization failure is fatal before Phase 1.
- A listener count of zero is “not serving,” not a successful empty measurement.
- Guest validation output must travel back to the host before any failed appliance is removed.
- Before rebuild, capture VM configuration, console screenshot/serial output if available, cloud-init log, journal, `ip address`, routes, listener census, config test output, and config hash.
- Keep diagnostics under a timestamped `logs\dhcp-appliance` directory.
- Never log credentials or private key material.
- Serialize appliance/configuration mutation with a host-wide named mutex so two MemLabs processes cannot reconcile concurrently.

## Implementation phases

### Phase 1 — Capability detection and safe opt-in

- Add structured host/backend detection.
- Make Client `Install-HyperV` avoid ServerManager/DHCP role calls.
- Select `DnsmasqAppliance` automatically on Client while retaining explicit capability evidence in `$Common.DhcpBackend`.
- Add unit tests for Client/Server capability matrices.

### Phase 2 — Provider abstraction

- Add the provider API and native Windows implementation.
- Refactor DHCP consumers in network creation, allocation, reservations, cleanup, validation, and probes.
- Add a lexical/AST gate preventing direct DHCP cmdlets outside provider-owned files.
- Prove existing Server deployments produce equivalent calls/results.

### Phase 3 — Desired-state compiler and appliance notes

- Build canonical state from deployment config, live VM notes/topology, and surviving appliance placement notes.
- Add schema-versioned appliance ownership notes and conflict validation.
- Add tests for multiple domains, secondary networks, shared Internet/Cluster, missing notes, duplicates, and stale state.

### Phase 4 — Appliance creator and guest reconciler

- Add multi-NIC MAC-bound cloud-init generation.
- Add appliance VM creation, ownership marker, sharding, SSH readiness, and diagnostic capture.
- Add `dnsmasq` render/apply/validate scripts.
- Verify image download occurs for Client mode without a Linux role in the user config.

### Phase 5 — New-Lab lifecycle integration

- Split switch/NAT transport creation from DHCP creation.
- Reconcile the appliance after files and networks are ready but before `Set-DeployConfigIPAddresses`/Phase 1.
- Keep GenConfig startup read-only; reconcile existing labs only after deployment selection and validation.
- Add a second health gate before PXE/relay operations.

### Phase 6 — Recovery and cleanup

- Add in-place repair, missing-VM rebuild, corrupt-disk rebuild, host-state reconstruction, and safe cleanup.
- Integrate domain/all removal and prevent infrastructure VMs from appearing as orphans.
- Preserve full diagnostics before destructive recovery.

### Phase 7 — Client rollout validation

- Run the full Client integration suite before merging the automatic selection change to a release branch.
- Retain a command that prints the selection evidence for troubleshooting.

## Test matrix

### Unit/dual-engine tests

Run under PowerShell 7 and Windows PowerShell 5.1 where applicable:

- Client/Server capability selection.
- Desired-state compilation and canonical ordering.
- Atomic write failure preserves the prior state.
- Scope/reservation conflict rejection.
- Stable shard assignment and the eight-NIC limit.
- Renderer equivalence for router/DNS/domain/WINS/lease options.
- Ownership proof and refusal to delete unknown VMs.
- Removal of one domain preserves other domains.
- Direct-DHCP-cmdlet gate fires on a known bad fixture and is clean on the tree.

### Client-host integration tests

1. Fresh startup with no labs creates no appliance.
2. First deployment creates the appliance before Phase 1 and boots Windows and Linux guests.
3. Direct PXE on a DP subnet completes DHCP/PXE/TFTP.
4. Relayed PXE completes across subnets without port 67/69/4011 conflicts.
5. Stop `dnsmasq`: next reconciliation repairs it.
6. Corrupt the guest config: invalid candidate is rejected; next reconciliation restores the last valid desired state.
7. Delete one appliance VM: next MemLabs launch recreates it with identical scope/reservation hashes.
8. Delete its OS disk: diagnostics are captured and it is rebuilt.
9. Replace the reserved VM name with an unowned VM: MemLabs refuses deletion.
10. Corrupt/remove appliance placement notes: desired state reconstructs from lab VM notes/topology without losing other labs.
11. Create more than eight scopes: additional shard is created and each scope has exactly one server.
12. Remove one domain, then remove all; unrelated scopes survive the first operation and all appliance state is cleaned by the second.
13. Verify a normal Windows Server deployment remains on native DHCP and produces no appliance artifacts.

## Acceptance criteria

The feature is complete when:

- A clean Windows Client host can deploy a representative MemLabs configuration without Windows DHCP Server installed.
- Existing Windows Server behavior is unchanged.
- Windows, Linux, direct-PXE, and relayed-PXE clients all obtain the expected network configuration.
- Deleting an appliance and rerunning MemLabs reconstructs every provable scope/reservation from VM notes and preserves other labs; transient dynamic clients reacquire leases.
- Corruption recovery never deletes an unowned VM and never activates an invalid DHCP configuration.
- Failure before DHCP readiness stops the deployment with complete host-side diagnostics.
- Server and Client backends pass the same provider contract tests.
