---
description: "Use when editing PowerShell in memlabs (.ps1/.psm1), especially when changing error handling, adding a trap or Set-StrictMode, writing a diagnostic/watchdog, or adding a lint gate. Covers silent-failure shapes the parser and PSScriptAnalyzer both miss."
applyTo: "**/*.ps1, **/*.psm1, **/*.psd1"
---

# Failure semantics

These rules exist because each one already cost a build. Cited commits are real.

## Changing error handling rewrites the whole file, not your diff

Adding or broadening a top-level `trap`, `Set-StrictMode`, `$ErrorActionPreference = 'Stop'`,
or a scope-wide `-ErrorAction Stop` in an **existing** file retroactively promotes every
latent non-terminating error in that file to fatal. It is never a localized diagnostic
improvement. Audit the entire file before shipping it, not the lines you touched.

`3e597e9b` added `trap { ...; break }` to a 1200-line ScriptWorkFlow.ps1. That turned a
2022 typo into a fatal exit and hung a ConfigMgr hierarchy for 80+ silent minutes (`77fe21ed`).

## If your change delegates failure reporting, open the reporter and confirm it covers the new path

Do not write "X owns the failure decision" in a comment without reading X. The watchdog
that trap delegated to armed only *after* a `while (!(Test-Path $json))` pre-loop, so a
death *before* the json was written was the one case it could never see. Two correct-looking
pieces, one uncovered seam.

## Proof that a wait can never clear must FAIL, not warn

A warning on a repeating loop is indistinguishable from progress and burns the whole
timeout budget. If code has enough evidence to log "this cannot clear on its own", it has
enough evidence to stop. The host printed exactly that sentence every 5 minutes for 80
minutes (`0adaf631` made it fail after 3 confirmations).

## Silent-failure shapes the parser and PSScriptAnalyzer both miss

A bare word followed by `=` is a dropped `$`. PowerShell parses it as a **command call**,
throws `CommandNotFoundException` at run time, and says nothing under default preferences:

```powershell
$propName = propName = "PSReadyToUse" + $psvm.VmName   # 'propName' is a COMMAND
```

Existing gates in `.git/hooks/pre-commit` (never bypass with `--no-verify`):

| Gate | Catches |
|---|---|
| `vmbuild/tools/Test-BarewordAssignment.ps1` | bare word + `=` (dropped sigil) |
| `vmbuild/tools/Test-OrphanGlobals.ps1` | `$global:`/`$script:` read but never assigned, name looks like a typo |
| `vmbuild/tools/Test-MandatoryParamCalls.ps1` | omitted Mandatory param -> job blocks forever on a prompt |
| `vmbuild/DSC/Test-PS51Patterns.ps1` | PS 7 syntax that fails in-guest on 5.1 |
| `vmbuild/DSC/Test-DscScriptBlocks.ps1` | backtick-escaped `$true`/`$false` in DSC `{ }` blocks |

When adding a gate: run it against the offending historical commit to prove it fires, and
against the whole tree to prove it is quiet. Prefer a shape with **zero** legitimate uses
over name resolution -- the DSC phase scripts call ~100 cmdlets that only exist in a VM.
