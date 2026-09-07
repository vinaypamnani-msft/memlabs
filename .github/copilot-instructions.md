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

## Evidence And Safety

- Preserve unrelated working-tree changes and never broaden a commit or push
  beyond the user-approved paths.
- Do not report a scanner or test as passing when it measured zero applicable
  inputs, skipped the changed path, or failed during setup.
- Do not run live lab, VM, DSC, ConfigMgr, SQL, Azure, download, or installation
  operations as validation without explicit user authorization and a named
  target.