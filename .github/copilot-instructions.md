# MemLabs Agent Workflow

## Independent Verification

- Treat production behavior, shared helpers, background jobs, remoting, DSC,
  deployment phases, configuration schemas, validation, diagnostics, recovery,
  and repository test gates as substantive changes.
- After implementing a substantive change and running its first focused check,
  delegate to **MemLabs Test** for independent test selection and execution.
  Give it the exact diff scope, behavioral claim, target PowerShell engines, and
  validation already performed.
- Then delegate to **MemLabs Review** with the same scope plus the test results.
  Ask it to review logic, failure semantics, regressions, and missing coverage.
- The specialists are read-only. The parent agent owns all edits and decides how
  to address findings. After a repair, repeat the affected focused tests and
  independent review before finalizing.
- Skip this delegation loop for documentation-only, comment-only, formatting,
  generated-output, or other behavior-neutral changes unless the user asks for
  review or testing.
- If a specialist is unavailable, perform its documented workflow directly and
  state that independent delegation was unavailable.

## Specialist Routing

- Delegate questions about ConfigMgr product internals, source-owned mechanism,
  or product regression history to **ConfigMgr Source Investigator**. Research
  MCP is mandatory first; Bluebird is allowed only after a documented Research
  source miss or confirmed Research service outage.
- Delegate slow builds, phase or VM cost, stalls, blocked jobs, worker leaks,
  resource pressure, critical paths, and performance-regression analysis to
  **MemLabs Performance**. Give it raw artifact paths and provenance rather than
  relying on pasted excerpts when those artifacts are available.
- Use the manually selected **MemLabs Live Ops** agent for live Hyper-V, VM,
  PowerShell Direct, deployment, DSC, ConfigMgr, SQL, network, checkpoint, VHD,
  or other lab-state operations. Other agents may perform read-only host and VM
  inspection under the standing authorization, but every state change must run
  synchronously through `vmbuild/tools/Invoke-MemLabsLiveOperation.ps1` and own
  its host-wide mutation lease for the full operation and postcondition check.
  Never break another session's lease or kill its owner to proceed.

## Evidence And Safety

- Preserve unrelated working-tree changes and never broaden a commit or push
  beyond the user-approved paths.
- Do not report a scanner or test as passing when it measured zero applicable
  inputs, skipped the changed path, or failed during setup.
- The user has granted standing authorization for live operations against all
  Hyper-V VMs on this host. Always name the target and classify the operation as
  Observe, Mutate, or Destructive. Observation may run concurrently. Mutation
  and destructive work must follow the **MemLabs Live Ops** lease protocol;
  destructive work must record the exact action, expected loss, and recovery
  path before execution.