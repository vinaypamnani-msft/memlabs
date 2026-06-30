# Maintenance Fixes

Each `*.ps1` file in this folder defines exactly one maintenance fix.
They are dot-sourced from inside `Get-VMFixes` (`Common.Maintenance.ps1`),
so they execute in that function's scope.

## Contract

When dot-sourced, the file MUST:

1. Define a script block containing the fix body. The body runs **inside the
   target VM** via PSRemoting, wrapped by `New-VMFixScriptBlock` which
   provides:
     - a transcript at `C:\staging\Fix\<FixName>.txt`,
     - a `Write-FixLog` helper (`-Level Info|Warning|Failure|Success`),
     - a structured `[pscustomobject]` return shape:
       `@{ FixName; Success; Message; Errors; ExceptionInfo; ComputerName; StartedAt; DurationSec; IsStructured }`.
   The body should return either `$true`/`$false` OR a `[pscustomobject]@{ Success; Message; Errors }`.

2. Append a fix descriptor to the host-scoped `$fixesToPerform` array:
   ```powershell
   $fixesToPerform += [PSCustomObject]@{
       FixName             = '<Unique-Name>'        # also used as transcript filename
       FixVersion          = 'YYMMDD[.n]'           # monotonically increasing
       NeededOnFreshDeploy = $true                  # $true = core code doesn't cover this; run even on fresh builds. $false = core already produces this state; skip on fresh deploy
       AppliesToExisting   = $true                  # apply to existing VMs
       AppliesToRoles      = @()                    # empty = all roles
       NotAppliesToRoles   = @()                    # excludes
       DependentVMs        = @()                    # VM names that must also be online
       ScriptBlock         = $Fix_X                 # the body defined above
       ArgumentList        = @(...)                 # optional, forwarded to body's param block
       RunAsAccount        = $vmNote.adminName      # optional, run under specific account
       InjectFiles         = @('Foo.ps1')           # optional, copied to C:\staging\
       InjectTools         = @('LogMachine')        # optional, copied to C:\tools\
   }
   ```

## Available variables

- `$vmNote`    — `Get-VMNote` result for the target VM (`$null` for dummy list).
- `$dc`        — Domain controller VM in the same domain.
- `$Common`    — Global memlabs config (e.g. `$Common.LocalAdmin.Password`).
- `$NewVM`     — `$true` if this is a freshly-built VM.
- `$fixesToPerform` — array to append into.

## Adding a new fix

1. Drop a new `Fix-<Name>.ps1` here.
2. Bump `FixVersion` whenever the body changes meaningfully so existing VMs
   re-apply the fix.

Load order within this folder is alphabetical, but **runtime execution order**
is determined by `FixVersion` (sorted ascending), not load order.
