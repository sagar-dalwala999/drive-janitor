# Drive Janitor — Spec (DAG)

**Working dir:** `C:\Users\VA-007\tools\drive-janitor`
**Stack:** Windows PowerShell 5.1 + WPF (PresentationFramework). No external deps, no install.

## Collision defense — READ THIS FIRST

Sagar's §0 forbids branches/commits, so there are **no git worktrees**. Isolation comes from
**strictly disjoint file ownership**. A slice that writes a file it does not own is a build bug.

`modules/Core.psm1` and `tests/Guard.Tests.ps1` are **FROZEN** — already written and verified
(22/22 guard tests green). No slice may edit them. If a slice believes Core is wrong, it returns
`BLOCKED: Core needs <change>` rather than editing it.

## The frozen Core contract (every slice consumes this)

```powershell
Import-Module "$PSScriptRoot\..\modules\Core.psm1"

New-Finding -Category <string> -Title <string> -Paths <string[]> -Bytes <long> `
            -Count <int> -Risk Safe|Moderate|Advanced `
            -Action Empty|Delete|RecycleBin|Dism|Report `
            -Detail <string> -Consequence <string>
# -> [pscustomobject] with those fields plus .Selected (defaults true only when Risk=Safe)

Test-PathProtected     -Path <string> -> [bool]   # fail-closed; ALWAYS call before any delete
Test-PathReparsePoint  -Path <string> -> [bool]   # junction/symlink detection, fail-closed
Clear-PathContents -Path <string> [-AlsoRemoveDir] -> [long] bytes freed  # >260-char safe, junction-safe, supports -WhatIf
Get-DirSize -Path <string> -> [long]
Format-Size -Bytes <long> -> "12.34 GB"
Write-JanitorLog -Message <string> -Level INFO|CLEAN|BLOCK|SKIP|ERROR
```

### Junctions — a verified data-loss hazard, not a theoretical one

`robocopy /MIR` purges **through** nested junctions and destroys the contents of whatever they
point at, anywhere on disk. `/XJ` does **not** prevent this — both behaviours were reproduced in a
sandbox on 2026-08-24. `Clear-PathContents` now unlinks nested reparse points
(`[IO.Directory]::Delete($p,$false)`, which can never recurse into a target) before mirroring, and
refuses outright to mirror onto a path that is itself a reparse point.
`tests/Junction.Tests.ps1` locks this in — 6/6 green.

**Consequences for scanners (S1-S4):** node_modules on pnpm projects contains thousands of
junctions (3,879 in one project on this machine). A scanner must NEVER follow a reparse point when
recursing, or it will double-count sizes and report paths outside the tree. Filter with
`Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) }` on every recursive
enumeration. Sizes computed by following junctions are wrong and will break the 5% reclaim
accuracy criterion.

**Every scanner exports exactly one function: `Invoke-<Name>Scan` taking `-Roots [string[]]`
and returning `[pscustomobject[]]` of findings.** Nothing else. No side effects, no deletion,
no writes to disk. Scanners are pure read-only.

**Risk semantics (be honest, the GUI pre-ticks only `Safe`):**
- `Safe` — regenerates automatically on next build/launch. No user action to restore.
- `Moderate` — regenerates but costs a re-download or a reinstall command.
- `Advanced` — irreversible, or needs judgment. Never pre-ticked.

## The S6 <-> S7 orchestration contract (pinned — both slices build against this verbatim)

S7 owns orchestration and exposes it as a **pure synchronous function**. S6 owns all threading and
calls that function inside its own runspace. Neither slice may invent its own version.

```powershell
# DEFINED BY S7 in DriveJanitor.ps1. CALLED BY S6 from inside its runspace.
Invoke-AllScans -Roots <string[]> [-ProgressCallback <scriptblock>] -> [pscustomobject[]]   # findings

# S7 invokes the callback as it goes; S6 supplies one that marshals to the UI thread:
& $ProgressCallback ([pscustomobject]@{
      Stage           = 'BuildCache'|'BrowserApp'|'Projects'|'System'
      CurrentPath     = <string>
      PercentComplete = <int 0-100>
  })
```

S7's function must never touch a WPF object; S6 must never call a scanner module directly.
That single boundary is what keeps the two slices independent.

## The S5 result contract (pinned — S6 binds its result panel to these exact field names)

A whole-drive free-space delta is **not** a trustworthy measure of what this tool reclaimed: other
processes write to disk during a multi-minute clean. So the honest number and the informational
number are separate fields, and only the deterministic one gates acceptance.

```powershell
Invoke-Clean -> @{
    Predicted             = <long>   # sum of scanner-measured sizes
    ActualPathBytes       = <long>   # sum of per-path (size-before - size-after). DETERMINISTIC.
    ActualDriveDeltaBytes = @{ 'C:' = <long>; 'D:' = <long> }   # informational ONLY, may be noisy
    Cleaned = @(); Skipped = @(); Blocked = @(); Errors = @()
}
```

**The 5% acceptance criterion is measured against `ActualPathBytes` vs `Predicted`, never against
the drive delta.** The GUI shows the drive delta clearly labelled as approximate.

## Sprints

| id | name | mode | depends_on | parallel_safe_with |
|---|---|---|---|---|
| S1 | Build + package cache scanner | A | [] | S2,S3,S4,S5,S6,S7 |
| S2 | Browser + app cache scanner | A | [] | S1,S3,S4,S5,S6,S7 |
| S3 | node_modules reaper + stale/dupe finder | A | [] | S1,S2,S4,S5,S6,S7 |
| S4 | Windows system reclaim scanner | A | [] | S1,S2,S3,S5,S6,S7 |
| S5 | Cleaner engine + dry-run + CSV export | A | [] | S1,S2,S3,S4,S6,S7 |
| S6 | WPF GUI | A | [] | S1,S2,S3,S4,S5,S7 |
| S7 | Entry point + config + shortcut installer | A | [] | S1,S2,S3,S4,S5,S6 |

All seven are `depends_on: []` because every one codes against the frozen Core contract above.
They integrate at the end, not with each other during the build.

### S1 — `modules/Scanner.BuildCache.psm1` (owns this file only)
`Invoke-BuildCacheScan -Roots`. Must find, each as its own finding:
- `android\build` + `android\.cxx` anywhere under roots **including inside `node_modules`** — this
  is the biggest category on this machine (41 GB found on 2026-08-24). Risk `Safe`.
- `.gradle\caches\<version>` transient dirs (e.g. `9.0.0`, `8.14.3`) — Risk `Safe`. **Must exclude
  `modules-2`**, which is the dependency jar cache.
- `.gradle\daemon`, `.gradle\native`, `.gradle\wrapper\dists` (Risk `Moderate` — re-downloads).
- Web/py build output: `.next`, `dist`, `build` at project root, `.venv`, `venv`, `__pycache__`,
  `target` (Rust/Maven), `.turbo`, `.parcel-cache`. Risk `Safe` except `.venv`/`venv` = `Moderate`.
- Package manager caches: npm, pnpm store, yarn, bun, nuget, pip. Risk `Moderate`.
- `%TEMP%`, `C:\Windows\Temp`. Risk `Safe`. Must exclude the running tool's own staging dir.

Performance matters: a naive full-tree `Get-ChildItem -Recurse` over D: takes minutes. Prune —
once you match `android\build`, do not descend into it.

### S2 — `modules/Scanner.BrowserApp.psm1` (owns this file only)
`Invoke-BrowserAppScan -Roots`. Chrome/Edge/Brave `User Data`: per-profile `Service Worker`,
`Code Cache`, `GPUCache`, `Cache`; plus `OptGuideOnDeviceModel` (3.98 GB here — the on-device
Gemini model, re-downloads). AI/dev tool caches: `.cache\codex-runtimes`, `.cache\huggingface`,
`.gemini\antigravity-backup`, `.codeium\database`, VS Code `CachedExtensionVSIXs`/`Code Cache`,
`ms-playwright*` browser bundles. All `Moderate` (they re-download). **Never touch profile data
— bookmarks, cookies, history, Login Data, Local Storage.** Detect a running browser and mark
those findings with a `Consequence` saying the browser must be closed first.

### S3 — `modules/Scanner.Projects.psm1` (owns this file only)
`Invoke-ProjectScan -Roots`.
- **node_modules reaper**: every `node_modules` (top-level only, not nested), with size + days
  since the *project* was last modified (check sibling `package.json`/`src` mtime, not
  node_modules' own). Rank by age. Risk `Moderate`, `Consequence` names the exact restore command
  inferred from the lockfile (`npm ci` / `pnpm i` / `yarn`).
- **Stale project finder**: project dirs with no git remote AND no modification in 90+ days.
  Action `Report` — never cleanable.
- **Duplicate finder**: near-identical sibling project dirs. Compare cheaply — `package.json`
  name+version, then a sampled file-hash of up to 50 shared relative paths. `D:\A` vs `D:\Pulse`
  are the known real case. Action `Report`, Risk `Advanced`, and report the *evidence*
  (% of sampled files identical), never a delete recommendation.

### S4 — `modules/Scanner.System.psm1` (owns this file only)
`Invoke-SystemScan -Roots`. Recycle bins per drive (Action `RecycleBin`); `Downloads` triaged by
age with a big-file breakdown (Risk `Advanced`, Action `Report` + opt-in delete); Windows Update
cache `SoftwareDistribution\Download`; `Windows\Installer` orphaned patches (**detect only, never
delete** — Action `Report`, orphan detection is unreliable and breaks repair/uninstall);
WinSxS component store (Action `Dism`, Risk `Advanced` — report the analyzable reclaim from
`DISM /Online /Cleanup-Image /AnalyzeComponentStore`, needs admin); hibernation file (Action
`Report` with the `powercfg /h off` command, never automated); big-file finder (files >500 MB
outside protected paths, Action `Report`).

### S5 — `modules/Cleaner.psm1` (owns this file only)
`Invoke-Clean -Findings <pscustomobject[]> [-DryRun] [-ProgressCallback <scriptblock>]`.
- Dispatch per `Action`: `Empty`/`Delete` → `Clear-PathContents`; `RecycleBin` → `Clear-RecycleBin`;
  `Dism` → the DISM command with an admin check; `Report` → **never cleaned, skip with a log line**.
- **Call `Test-PathProtected` on every path immediately before acting, even though scanners
  filtered** — defense in depth, and a scanner bug must not become data loss.
- Sort targets deepest-first so a nested target is not orphaned by its parent's removal.
- `-DryRun` returns the full would-delete path list + predicted bytes, touching nothing.
- Measure real reclaim as a `Get-PSDrive` free-space delta per drive, and return **both** predicted
  and actual so the GUI can show honest numbers. Acceptance criterion is within 5%.
- Locked/in-use files: skip, collect into a `Skipped` list, never throw.
- Return `@{ Predicted; Actual; Cleaned=@(); Skipped=@(); Blocked=@(); Errors=@() }`.
- Also export `Export-FindingsCsv -Findings -Path`.

### S6 — `ui/MainWindow.xaml` + `ui/Gui.ps1` (owns these two files only)
WPF window, launched by S7. Layout per the approved mockup:
- Header: one bar per drive — free/total, % free, colour by pressure (red <10%, amber <20%, green).
- `[ Scan ]` button; determinate progress + current-root label while scanning.
- Findings as a grouped, collapsible checkbox tree by Category; each row: title, size,
  count, Risk badge, and the `Consequence` line as sub-text or tooltip.
- Live "Selected: N GB" total that updates on tick.
- `[ Dry run ]` → modal listing exact paths. `[ Clean ]` → confirm dialog naming the total and
  the count of `Advanced` items, then progress, then a result panel: predicted vs actual, skipped.
- Advanced toggle reveals: custom root paths, min-size threshold, age threshold, exclusion list.
- **The scan must not freeze the window.** Use a runspace/`BeginInvoke` and marshal updates back
  via `Dispatcher.Invoke`. A hung UI on a 5-minute D: scan is a failed slice.
- Risk colour: Safe green, Moderate amber, Advanced red. `Report`-action rows render without a
  checkbox — they are informational and cannot be cleaned.

### S7 — `DriveJanitor.ps1`, `modules/Config.psm1`, `Install-Shortcut.ps1`, `README.md` (owns these four)
- `DriveJanitor.ps1`: entry point. Imports Core + all scanners + cleaner, loads the GUI, wires the
  scan orchestration (run all four scanners, aggregate findings). Supports `-CLI` for a
  no-GUI text run and `-DryRun`. Must work when double-clicked via the shortcut, which means
  handling the PowerShell execution policy (`-ExecutionPolicy Bypass` in the shortcut target)
  and STA threading for WPF (`-STA`).
- `modules/Config.psm1`: load/save `config.json` (roots, thresholds, exclusions, last scan).
- `Install-Shortcut.ps1`: create a Desktop + Start Menu shortcut with a sensible icon, `-STA
  -ExecutionPolicy Bypass`, working dir set. Idempotent.
- `README.md`: what it does, how to run, what each Risk level means, how to add a custom root.

## Do not touch (any slice)
`modules/Core.psm1`, `tests/Guard.Tests.ps1`, `sprints/*`, `logs/*`, and any file owned by
another slice per the table above.
