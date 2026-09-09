# QA-Backend — MVP Round 1

Build: Drive Janitor — local Windows desktop app (PowerShell 5.1 + WPF), no db/auth/api/deploy/secrets.
Reviewer: QA-Backend (source + Bash/pwsh only — no Playwright, that's QA-User's lane).

## Question selection

- `qa_depth: deep` per brief.md header (dangerous_actions non-empty) → run **all 8** questions regardless of `capabilities:`, per the dispatch's own deep-build rule.
- Q2 (where do slugs land), Q3 (non-org email login), Q4 (what's exposed), Q6 (scale/db) — **skipped**. `capabilities: db=no, auth=no, api_routes=no, external_deploy=no, secrets=no, background_jobs=no`, confirmed by reading brief.md's header and the whole codebase (no HTTP listener, no credential store, no DB driver anywhere in `modules/` or `ui/`). These four questions have no surface to audit on a local single-user desktop tool; skipping them is not a passed check, it is "not applicable," and I'm stating that explicitly per the integrity rule.
- **Q1** (brief vs. deployed), **Q5** (source hygiene), **Q7** (foundation-file integrity), **Q8-adapted** ("does the thing that runs match the code," verified by actually running `DriveJanitor.ps1 -CLI` end-to-end against a sandbox fixture) — run in full, below.
- Bulk of effort per the task's explicit instruction went into the guard (`Test-PathProtected`), the four scanners' Safe/Delete calls, `Cleaner.psm1`'s dispatch integrity, honest-numbers verification, and scan performance — all with real, executed evidence, never reasoning-only.

All destructive/sandbox testing was done under `$env:TEMP` with synthetic fixtures I created and deleted myself. No real clean was run against this machine's actual C:/D: data. One read-only proof (`Test-Path` through a legacy Windows junction) touched a canary file I created and deleted myself under my own scratchpad — never anything pre-existing.

---

## Mental framework walkthrough

### Q1: Does what the brief promised actually exist?
**Verdict: DIVERGENCE (multiple, see findings below).** Walked brief.md §5 MVP Acceptance Criteria against the code and a live `-CLI` run:
- Scan + grouped findings w/ byte counts — PASS, verified by running `DriveJanitor.ps1 -CLI -DryRun` against a sandbox fixture (see Q8 below); real output table observed.
- Risk + plain-English Consequence line — PASS, `New-Finding` enforces it, `Integration.Tests.ps1` asserts non-empty.
- Dry-run touches nothing — PASS by code read: the `-DryRun` branches in `Cleaner.psm1` only call `Get-DirSize`/`Get-RecycleBinBytes` (read-only), never `Clear-PathContents`/`Clear-RecycleBin`/`dism.exe`.
- **Clean reclaims within 5% of predicted — FAIL.** See Finding 3.
- Duplicate finder (Report-only, evidence %) — PASS by code read, `Scanner.Projects.psm1` never emits a delete recommendation for duplicates.
- Advanced flow (custom root/exclusion persisted) — PASS by code read, `Config.psm1` + `Gui.ps1` wire this correctly.
- Junction safety, `Junction.Tests.ps1` green — PASS, ran it: `ALL JUNCTION TESTS PASSED`.
- Protected-path guard test, `Guard.Tests.ps1` green — PASS, ran it: `ALL GUARD TESTS PASSED` (22/22).
- **Handles >260-char paths without error — FAIL, and worse than an error.** See Finding 3: it doesn't throw, it silently no-ops and mis-reports.
- Launches from shortcut, no extra software — structurally PASS (`Install-Shortcut.ps1` uses `-STA -ExecutionPolicy Bypass`, a shell32 icon fallback, correct working dir) — **but see Finding 2: even if it launches, clicking Clean crashes.**
- brief.md §6 "Export: Scan results exportable to CSV" — **FAIL.** See Finding 6.

### Q5: What's in source that shouldn't be?
**Verdict: DIVERGENCE.** Grepped for `SUPABASE_SERVICE_ROLE_KEY`/`API_KEY`/`password`/`secret`/hardcoded URLs — none found (correctly, this tool has no secrets surface). But **`ui/Gui.ps1` ships live debug instrumentation hardcoded to this QA session's own ephemeral scratchpad path** — see Finding 2. This is exactly the class of thing Q5 exists to catch, just not the "leaked credential" flavor since this build has no secrets — it's leaked *session state*.

### Q7: Did a sub-Generator break a foundation file?
**Verdict: PASS, with evidence.** Read `modules/Core.psm1` in full and diffed it by hand against spec.md's pinned "frozen Core contract" (`New-Finding`, `Test-PathProtected`, `Test-PathReparsePoint`, `Clear-PathContents`, `Get-DirSize`, `Format-Size`, `Write-JanitorLog`) — signatures match exactly, nothing added/removed. Ran `tests/Guard.Tests.ps1` directly: `ALL GUARD TESTS PASSED`. No slice touched the frozen file. (Note: Core.psm1 itself has a real, unrelated gap — Finding 1 — but that's a pre-existing hole in the frozen contract, not a slice violating "do not touch.")

### Q8 (adapted — does the thing that runs match the code):
**Verdict: PASS for the CLI path, with a caveat for the GUI path (Finding 2).** Built a small sandbox fixture (`android/app/build`, `node_modules`, `package.json`) under `$env:TEMP`, pointed a temporary `config.json` at it, and ran `DriveJanitor.ps1 -CLI -DryRun` for real. It imported all modules, ran all four scanners, printed a findings table, and dry-ran correctly — genuine end-to-end proof the entry point works as coded. Cleaned up the temp `config.json` and fixture afterward (no config.json existed before my test; none exists now). The GUI path is a different story — see Finding 2.

---

## Finding 1 — CRITICAL — `Test-PathProtected` and `Test-PathReparsePoint` are both blind to `C:\Documents and Settings\<user>\...`, a live Windows junction back into the real user profile

This is a genuinely new bypass shape, not one of the excluded/already-covered classes (trailing space/dot, `..`, 8.3, UNC, ADS, drive roots, `.git`, `modules-2`, source dirs, Android SDK).

Every Windows install since Vista ships a hidden compatibility junction, `C:\Documents and Settings`, pointing at `C:\Users`. It is real, present, and traversable by a normal (non-elevated) process on this machine — verified live, not assumed:

```
Test-Path -LiteralPath 'C:\Documents and Settings'                          -> True
(Get-Item 'C:\Documents and Settings' -Force).Attributes                    -> Hidden, System, Directory, ReparsePoint, NotContentIndexed
Test-Path -LiteralPath 'C:\Documents and Settings\VA-007\Desktop'            -> True
```

I then created a canary file under my own scratchpad via the real `C:\Users\...` path, and read it back through the alias — proving the alias resolves to the *same real object*, not a dead/empty stub:

```
$markerReal = 'C:\Users\VA-007\AppData\Local\Temp\...\scratchpad\qa-alias-marker'
'CANARY' | Set-Content (Join-Path $markerReal 'canary.txt')
$viaAlias  = 'C:\Documents and Settings\VA-007\AppData\Local\Temp\...\scratchpad\qa-alias-marker'
Test-Path -LiteralPath $viaAlias                                            -> True
Get-Content (Join-Path $viaAlias 'canary.txt')                              -> CANARY
```

Then called the actual guard functions from `modules/Core.psm1` against the alias path (read-only calls, zero mutation):

```
Test-PathProtected('C:\Users\VA-007')                                       -> True   (correct, per Guard.Tests.ps1)
Test-PathProtected('C:\Documents and Settings\VA-007')                      -> False  <-- SAME REAL FOLDER, different string
Test-PathProtected($viaAlias)                                               -> False
Test-PathReparsePoint($viaAlias)                                            -> False  <-- independent defense-in-depth ALSO misses it
Resolve-JanitorPath($viaAlias)                                              -> returned the alias string unchanged (no canonicalization to the real path)
```

**Why both layers miss it:** `$script:ProtectedExact` lists the literal strings `'C:\Users'` and `"$env:USERPROFILE"` — not the alias. None of the five `$script:ProtectedPatterns` regexes reference "Documents and Settings". `[IO.Path]::GetFullPath()` does not resolve reparse points for an already-absolute path with no `..`/`.` segments, so `Resolve-JanitorPath` never converts the alias to its real target. `Test-PathReparsePoint` only inspects the *final resolved path's own* attributes via `Get-Item` — once you're past the top-level junction segment, Windows resolves it transparently and every subsequent segment shows normal (non-reparse) attributes, so the check that exists specifically to catch reparse-point traversal doesn't fire either.

**Reachability, honestly stated:** no scanner in this codebase currently constructs a path through "Documents and Settings" — I found zero references to it anywhere in `modules/` or `ui/`. This is not a confirmed live incident. But `Test-PathProtected` is, per spec.md's own words, "the single guard between a scanner bug and permanent data loss," explicitly designed as defense-in-depth against *arbitrary* bad paths a scanner (present or future) or a hand-typed Advanced-flow custom root/exclusion could produce — not just the specific strings scanners happen to emit today. A guard whose two independent layers can both be defeated by a single well-known, always-present OS alias is a structural hole in the one file every slice trusts completely, and it fits Core Element #1 ("It never destroys work... a single false positive kills trust permanently") precisely because the whole point of the guard is to hold even when a scanner is wrong.
**Required fix:** canonicalize through `[IO.Path]::GetFullPath` is not enough — resolve the path to its real target (or block known legacy OS junction aliases by name, the same way `Android\Sdk` is already blocked by name) before running the exact/pattern checks.

---

## Finding 2 — CRITICAL — shipped GUI code contains hardcoded debug logging to an ephemeral, session-specific temp path; every real click of the Clean confirm dialog throws an unhandled exception

`ui/Gui.ps1` contains **7 separate `Add-Content -LiteralPath` calls** hardcoded to:
```
C:\Users\VA-007\AppData\Local\Temp\claude\C--Users-VA-007\f4f8ee10-a297-462d-85bb-8503c85a62ed\scratchpad\click-debug.log
```
at lines 286, 288, 290, 296, 307, 578, 610 — inside `Show-ConfirmDialog`'s Yes/No button handlers, inside `Show-ConfirmDialog`'s post-`ShowDialog()` return path, and inside `BtnClean`'s click handler (both before *and* inside the try/catch). This is a specific Claude-agent scratchpad directory (`f4f8ee10-a297-...`), almost certainly left over from a previous fix-round debugging the "`Show-ConfirmDialog` never returns" issue documented in the code comment directly above it (line ~248-252) — and never removed before the slice was marked done.

Verified the failure mode directly:
```powershell
Add-Content -LiteralPath 'C:\Users\...\Temp\claude\NONEXISTENT-SESSION-GUID-12345\scratchpad\click-debug.log' -Value 'test' -ErrorAction Stop
# THREW: System.IO.DirectoryNotFoundException: Could not find a part of the path '...'
```
`Add-Content` creates a missing *file* but not missing *parent directories* — confirmed it throws `DirectoryNotFoundException` the instant the directory doesn't exist. That exact directory is a per-session Claude Code scratchpad, tied to one specific past agent session's GUID — it will not exist on any other machine, any other day, or even the *next* Claude Code session on this same machine. It happens to exist right now purely because I am running this QA review inside the same session lineage that wrote the debug code.

I confirmed via `grep` there is **no global unhandled-exception handler anywhere in the codebase** (`DispatcherUnhandledException`, `trap`, etc. — zero matches across `ui/` and the entry point). PowerShell WPF click handlers added via `.Add_Click({...})` have no implicit exception boundary; an unhandled exception inside one will propagate up through the `ShowDialog()` message pump.

**Concrete consequence:** on the very next real launch of Drive Janitor (the actual desktop shortcut, any session other than the one that wrote this debug code), clicking **Yes** or **No** on *any* confirm dialog — including the mandatory Clean confirmation required by Core Element #2 ("Scan-then-confirm... the user ticks them and hits Clean") — throws before the click handler can finish. At minimum the Clean flow never completes as intended; worst case it crashes the whole window. Either way, **the tool's central destructive action is currently unusable outside the exact debugging session that left this in.**
**Required fix:** remove all 7 debug `Add-Content` calls from `ui/Gui.ps1`.

---

## Finding 3 — CRITICAL — long-path (>260 char) handling is broken end-to-end for both scan-time sizing and clean-time execution, on the tool's #1-ranked, "41 GB found" flagship category

Two distinct, both-confirmed failure modes, tested with real fixtures under `$env:TEMP` and real end-to-end calls through `Invoke-BuildCacheScan` → `Invoke-Clean` (the actual production pipeline, not a shortcut around it).

**3a — scan-time: `Scanner.BuildCache.psm1`'s own sizing (`Get-JunctionSafeDirSize`) silently returns 0 for a shallow, correctly-matched `.cxx`/`build` folder whose *contents* are deep.** This is the realistic shape (CMake nests ABI/build-type/hash folders many levels under a shallow `.cxx`): I created an 88-char `.cxx` folder containing a 287-char nested file, ran the real scanner:
```
AndroidBuild finding: Bytes=0 (truth=2097152) Paths=...\proj\android\.cxx
Predicted=0   ActualPathBytes=2097152   (the real robocopy clean genuinely freed the 2 MB — the scan just never told the user it was there)
```
Root cause: `Get-JunctionSafeDirSize` (private to `Scanner.BuildCache.psm1`) walks with plain `Get-ChildItem -LiteralPath`, not Core's own `Get-DirSize` (robocopy-based, already proven long-path-safe by `Sizing.Tests.ps1`, which explicitly exists because "`Get-ChildItem -Recurse` silently returns 0 for paths over 260 chars"). Every one of this scanner's 7 finding categories (AndroidBuild, GradleVersionCache, GradleTransient, WebBuildOutput, PyVenv, package-manager caches, temp dirs) computes bytes the same way — this is not a one-off, it's the scanner's only sizing path, and it's the exact anti-pattern Core.psm1's own docstring names by number.

**3b — clean-time: when the *matched finding root itself* exceeds ~260 chars (equally realistic for deeply-nested module/variant/ABI Android trees), `Invoke-Clean` silently no-ops and mislabels it.** Constructed a 340-char finding root, ran the real `Invoke-Clean`:
```
Predicted=3145728   ActualPathBytes=0
Skipped: [{"...","Reason":"path no longer exists"}]     <- FALSE. The 3 MB file is still there.
CMakeCache.txt (3 MB) STILL ON DISK after Invoke-Clean: True
```
Root cause: `Cleaner.psm1` line ~175 (`if (-not (Test-Path -LiteralPath $p))`) and `Core.psm1`'s own `Clear-PathContents` (same check, plus `Test-PathReparsePoint`'s `Get-Item -LiteralPath`) all use classic, non-long-path-aware PowerShell cmdlets. Confirmed the machine has `LongPathsEnabled = 0` (registry-checked directly), so any >260-char target silently reads as "doesn't exist" — the robocopy call inside `Clear-PathContents` (which *is* long-path-safe, proven in 3a's Actual number and in `Junction.Tests.ps1`) is never even reached.

**Compounding effect on the acceptance criterion:** the MVP AC ("Clean reclaims within 5% of predicted, `ActualPathBytes` vs `Predicted`") compares two numbers that can *both* independently be wrong from this same root cause, in opposite directions depending on which of 3a/3b fires. In 3a, Predicted=0 while Actual is correct — findings this shape will simply never surface as worth cleaning to the user (they render as ~0 bytes and get ignored), silently leaving the real GBs on disk despite Safe+pre-ticked status. In 3b, Predicted is correct but Actual is 0 with a false "path no longer exists" label — a 100% miss that blows through 5% and tells the user something was cleaned when it wasn't touched at all. **The 5% check cannot catch either shape because it never compares to ground truth (actual disk state) — only Predicted to Actual, and this bug can corrupt both the same way.**
**Required fix:** make `Scanner.BuildCache.psm1` use Core's `Get-DirSize` (already junction-safe via `/XJ`, already long-path-safe via robocopy) instead of its own `Get-ChildItem`-based walk; make `Cleaner.psm1`'s and `Core.psm1`'s existence/reparse checks long-path-safe (e.g. the `\\?\`-prefix technique `Scanner.Projects.psm1` already uses correctly for its own sizing).

---

## Finding 4 — CRITICAL (honest numbers) — `SourceAncestors`' `'styles'` entry blocks Safe/Delete cleaning of `__pycache__` inside extremely common vendored Python packages, confirmed from this tool's own real production log

`Test-PathProtected` treats `styles` as a protected *ancestor* segment anywhere in a path (intended to protect a web app's `src/components/styles`). `pygments`, `openpyxl`, and `python-docx` — all commonly vendored/installed packages on a dev box — ship a `styles/` submodule, and Python's bytecode cache sits directly under it as `styles\__pycache__`. `Scanner.BuildCache.psm1` correctly classifies `__pycache__` as Risk=Safe, Action=Delete (regenerable), but the "styles" ancestor rule blocks it before it can ever be cleaned.

This is not theoretical — it's already in `logs/run-2026-08-24.log` from a real run on this machine:
```
19:10:33 [BLOCK] defense-in-depth refused: C:\Users\VA-007\.cache\codex-runtimes\...\pip\_vendor\pygments\styles\__pycache__
19:10:33 [BLOCK] defense-in-depth refused: C:\Users\VA-007\AppData\Local\Programs\Python\Python311\Lib\site-packages\pip\_vendor\pygments\styles\__pycache__
19:10:34 [BLOCK] defense-in-depth refused: C:\Users\VA-007\.claude\security\agent-sdk-venv\Lib\site-packages\pip\_vendor\pygments\styles\__pycache__
19:10:35 [BLOCK] defense-in-depth refused: ...\openpyxl\styles\__pycache__   (x2, different envs)
19:10:35 [BLOCK] defense-in-depth refused: ...\docx\styles\__pycache__
19:10:36 [BLOCK] defense-in-depth refused: C:\edb\languagepack\v4\Python-3.11\Lib\site-packages\pip\_vendor\pygments\styles\__pycache__
```
The exact log message text (`"defense-in-depth refused: $p"`) only originates from `Cleaner.psm1`'s pre-delete `Test-PathProtected` re-check — meaning this happened during a real `Invoke-Clean` call, on real pre-ticked Safe findings, not a scan-only dry pass. `Predicted` counts these bytes (computed at scan time, before the block); `ActualPathBytes` won't include them — another concrete, already-observed source of Predicted/Actual mismatch beyond Finding 3, and it will recur on *any* machine with pip, its vendored pygments copy, or openpyxl/docx installed (i.e., most Python dev boxes).
**Required fix:** narrow the `SourceAncestors` match (e.g. require it be the *immediate* parent of a recognizable source-project layout, or drop `'styles'`/other generic names from the ancestor list and keep them only as leaf-name protection).

---

## Finding 5 — CRITICAL/owner-opinion (flagging as critical, Main Claude should weigh the "no explicit time SLA in brief.md" nuance) — scan performance: three independent, redundant full-drive tree walks, none excluding non-project system trees

Read all four scanners and `DriveJanitor.ps1`'s `Invoke-AllScans`. Confirmed via the tool's own real log (`BuildCache scan: C:\`, `BuildCache scan: D:\`, `Invoke-ProjectScan starting: roots=C:\, D:\`) that real runs use the raw drive roots from `Get-DefaultJanitorConfig` (`@('C:\','D:\')`).

**Root cause, specific and code-grounded:**
1. `Scanner.BuildCache.psm1`'s `Find-BuildCacheCandidates` does a full recursive directory walk of every root, pruning only at name matches.
2. `Scanner.Projects.psm1`'s `Find-ProjectTree` does a **second, entirely independent** full recursive walk of the same roots — and does *more* per-node work than BuildCache's walk: it calls `[IO.File]::Exists(Join-Path $io 'package.json')` at **every single directory it visits, system-wide** (one extra filesystem stat per node), which plausibly explains why Projects (727s) is ~5x slower than BuildCache (150s) despite BuildCache actually recursing *deeper* (it must descend into every `node_modules` looking for nested `android\build`, which Projects explicitly prunes and never enters).
3. `Scanner.System.psm1`'s `Get-BigFileFinding` does a **third** independent full walk per root (for files >500 MB), pruning by directory *name* only after Test-PathProtected/PruneNames checks.

None of the three walks share results with each other, and **none exclude `C:\Windows`, `C:\Program Files`, `C:\Program Files (x86)`, or `C:\ProgramData`** from traversal — despite `Test-PathProtected` already knowing unconditionally that nothing under those trees is ever a legitimate finding. All three walks pay the full enumeration cost of Windows' own multi-hundred-thousand-directory system trees for zero possible payoff.
**Required fix:** either consolidate the three walks into one shared traversal that all four category-matchers consume, or at minimum have `Invoke-AllScans`/each scanner exclude the known-empty system trees (`C:\Windows`, `Program Files*`, `ProgramData`) from the recursive walk entirely, and drop the per-node `package.json` existence stat from `Find-ProjectTree`'s hot path.

---

## Finding 6 — MINOR (brief-vs-deployed divergence) — CSV export exists in the code but is unreachable from the GUI

brief.md §6 Phase 0 assumptions: "Export: Scan results exportable to CSV." spec.md pins this into S5's scope: `Export-FindingsCsv -Findings -Path`. The function exists, is exported from `Cleaner.psm1`, and `tests/Integration.Tests.ps1` confirms it's callable. But grepped `ui/MainWindow.xaml` and `ui/Gui.ps1` for `Csv`/`Export` — **zero matches**. The only buttons in the shipped window are Scan, Dry run, Clean, Advanced toggle, and Save settings. A real user has no way to trigger a CSV export; the feature is fully built and completely inaccessible.
**Required fix:** add an Export button/menu item wired to `Export-FindingsCsv`.

---

## Finding 7 — MINOR (spec adherence) — `Cleaner.psm1`'s RecycleBin dispatch skips the stated "call Test-PathProtected on every path immediately before acting" invariant

spec.md's S5 section states this defense-in-depth rule applies to every destructive dispatch. The `Empty`/`Delete` branch (`fsWork` loop) does call it; the `RecycleBin` branch (`rbFindings` loop, calling `Clear-RecycleBin -DriveLetter $dl`) does not call `Test-PathProtected` at all. Practical exploitability is low — `Get-JanitorDriveLetter` only ever extracts a single drive-letter character via regex before it reaches `Clear-RecycleBin`, which takes a drive letter, not a path, so none of the guard's path-traversal-style checks would apply here anyway — but it's a literal, silent deviation from a safety invariant the spec states unconditionally for "every path," which is exactly the kind of gap a developer reading the code would notice and a user wouldn't.
**Required fix:** either add the `Test-PathProtected` call for consistency with the stated invariant, or amend spec.md's wording to scope the invariant to path-taking actions only.

---

## Finding 8 — OWNER-OPINION — `%TEMP%` is Risk=Safe / pre-ticked / Action=Empty, wiping a shared, actively-used OS scratch space in one click

This matches brief.md's own §3 spec (`%TEMP%`, `C:\Windows\Temp`, Risk Safe) exactly — it is not a code bug, it's a specified design choice, so I'm not calling it a divergence. Flagging it because Core Element #1 ("no false positive... kills trust permanently") is explicit and absolute, and `%TEMP%` is not a single application's disposable cache the way `.next`/`dist`/Gradle caches are — it's shared OS scratch space that many concurrently-running, unrelated processes (autosave files, installers-in-progress, IDE lock files, and — concretely — this very Claude Code session's own scratchpad, which this agent-psychology-mandated workflow instructs to use "instead of `/tmp`") write into and expect to still be there moments later. `Clear-PathContents`'s only carve-out is the tool's own robocopy staging dir; nothing distinguishes "orphaned cache file" from "another process's in-flight scratch file that merely isn't locked at this instant." I have no evidence this has destroyed anything on this run — flagging as a design risk for Main Claude/Sagar to weigh, not a proven incident.

---

## Overall verdict

**CRITICAL_ISSUES**

## Required fixes for main Claude (priority order)

1. [CRITICAL] Canonicalize `Test-PathProtected`/`Test-PathReparsePoint` against known legacy OS path aliases (`C:\Documents and Settings` → real `C:\Users` target) — Finding 1.
2. [CRITICAL] Strip all 7 hardcoded debug `Add-Content` calls from `ui/Gui.ps1` — Finding 2.
3. [CRITICAL] Make `Scanner.BuildCache.psm1`'s sizing and `Cleaner.psm1`/`Core.psm1`'s existence/reparse pre-checks long-path-safe end to end (scan-time and clean-time both currently break independently on >260-char paths) — Finding 3.
4. [CRITICAL] Narrow `Core.psm1`'s `SourceAncestors` `'styles'` entry so it stops blocking legitimate `__pycache__` cleans in vendored Python packages — Finding 4.
5. [CRITICAL/flag for judgment] Consolidate or scope the three independent full-drive scanner walks; exclude `C:\Windows`/`Program Files*`/`ProgramData` from all of them — Finding 5.
6. [MINOR] Wire `Export-FindingsCsv` to a GUI control — Finding 6.
7. [MINOR] Add `Test-PathProtected` to the RecycleBin dispatch branch, or narrow spec.md's stated invariant — Finding 7.
8. [OWNER-OPINION] Reconsider blanket `%TEMP%` Safe/pre-ticked/Empty, or at minimum exclude very-recently-modified files from what gets swept — Finding 8.
