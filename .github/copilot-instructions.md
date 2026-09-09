# MemLabs Agent Workflow

## Independent Verification

- Treat production behavior, shared helpers, background jobs, remoting, DSC,
  deployment phases, configuration schemas, validation, diagnostics, recovery,
  and repository test gates as substantive changes.
- For review/commit/push requests, freeze the initial path list before testing.
  "All working-tree changes" means that snapshot. Report paths created or
  changed concurrently after the snapshot; do not restart review or add them to
  the commit without explicit user approval.
- After implementing a substantive change and running its first focused check,
  delegate to **MemLabs Test** for independent test selection and execution.
  Give it the exact diff scope, behavioral claim, target PowerShell engines, and
  validation already performed.
- Then delegate to **MemLabs Review** with the same scope plus the test results.
  Ask it to review logic, failure semantics, regressions, and missing coverage.
- The specialists are read-only. The parent agent owns all edits and decides how
  to address findings.
- Bound independent verification to one initial **MemLabs Test** call and one
  initial **MemLabs Review** call. Batch all accepted repairs, rerun only the
  affected focused tests, then allow at most one closure call to each specialist
  for the complete repair batch. Do not recurse into one-finding-at-a-time
  review loops. If closure raises another variant in the same defect family,
  the parent must test the whole equivalence class directly and make the final
  decision without another specialist round.
- Reuse valid test evidence from the current session when the tested path bytes
  have not changed. Do not rerun an unchanged full matrix before review, after
  review, before commit, and after commit. The fast pre-commit hook proves only
  staged-byte safety, encoding, and syntax; semantic gates remain Test evidence.
- Prefer existing focused tests and checked-in gates. Do not build ad hoc nested
  PowerShell command harnesses for checks already covered by those tests. After
  one setup/quoting failure, switch to the existing script or a simple direct
  check instead of iterating on the harness.
- Run independent focused tests in parallel across unrelated change groups when
  their fixtures are isolated. Test both PowerShell engines only for code that
  actually runs under both; do not duplicate host-only checks under 5.1.
- Skip this delegation loop for documentation-only, comment-only, formatting,
  generated-output, or other behavior-neutral changes unless the user asks for
  review or testing.
- If a specialist is unavailable, perform its documented workflow directly and
  state that independent delegation was unavailable.

### Urgent Push-First Exception

When the user explicitly selects `Priority: urgent` and supplies exact paths,
commit message, and ownership mode, **MemLabs Push** may publish a feature-branch
commit before Test/Review delegation so remote labs can consume it immediately.

- Freeze hashes and the remote lease, run mandatory pre-commit hooks once, push,
  verify the remote SHA, and return the provisional commit first.
- Do not run optional tests, analyzers, Test, or Review before that push.
- MemLabs Push must run the required focused Test/Review after publishing and
  before ending, including when directly user-invoked. The parent runs any
  requested remote-lab validation against the published commit.
- Later findings are repaired in a new commit. Do not rewrite, conceal, or roll
  back the provisional commit unless the user explicitly requests it.
- Slow semantic gates run through MemLabs Test after an urgent push and before
  a normal or thorough push.
- This exception never permits hook bypass, ambiguous ownership, scope growth,
  weakened leases, destructive operations, or an unconfirmed unverified push to
  `main`, `master`, or `develop`.

## Fast Commit Path

Route an exact-path commit or push request to the **MemLabs Push** agent when the
user supplies or can confirm the paths, commit message, priority, and ownership
mode (`whole-file`, `patch`, or `commit`). Pass all valid same-session test/review
evidence so the agent can reuse it. Priority is:

- `urgent`: push exact feature-branch bytes first with hooks once, return the
  provisional SHA, then have MemLabs Push run Test/Review before ending; the
  parent owns requested remote-lab checks.
- `normal`: fill missing focused evidence, then publish.
- `thorough`: include only explicitly requested or blast-radius-justified wider
  checks before publishing.

The push agent owns only Git publication. It never repairs findings or expands
the approved path list.

When the user asks to review, commit, and push existing work, use this sequence:

1. Snapshot changed paths and the remote SHA once. Do not map the broader repo.
2. Group the snapshot by feature and inspect each diff directly. Do not call an
  Explore agent and MemLabs Review for the same scope.
3. Run missing focused tests once, parallelized by independent feature group.
  Reuse same-session results for unchanged files.
4. Invoke MemLabs Test once and MemLabs Review once for the complete snapshot.
5. Batch accepted repairs, run only affected tests, then use at most one bounded
  closure round. Apply the terminal closure rule above.
6. Run the fast pre-commit hook once. It does not replace semantic gate evidence.
  Commit with explicit pathspecs and verify each commit's path list.
7. Push with the frozen remote lease and verify the remote SHA. Do not rerun the
  unchanged test matrix after path-scoped commits.

For a previously tested clean snapshot, the normal path is inventory, missing
focused checks, one independent test/review pass, commit, and push. Stop and ask
the user before exceeding two Test calls, two Review calls, or one full matrix.

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