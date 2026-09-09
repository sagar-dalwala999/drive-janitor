# Drive Janitor — Brief

```yaml
slug: drive-janitor
tier: A
surface: ui                  # enum-valid; local WPF window, NOT web - no URL, no deploy
build_class: greenfield-crud
qa_depth: deep               # dangerous_actions is non-empty -> deep, per skill 6.0
ownership: personal
dangerous_actions:
  - permanent file/directory deletion on C: and D:
  - emptying recycle bins
  - DISM component-store cleanup (irreversible, removes rollback ability)
capabilities:
  db: no
  auth: no
  api_routes: no
  external_deploy: no
  secrets: no
  background_jobs: no
```

## 1. Product Overview

A zero-install Windows desktop app that finds and reclaims disk space on C: and D:, aimed at
a developer whose drives fill up from Android/Gradle/React Native build output. Replaces the
manual "ask Claude to run cleanup commands" loop with a repeatable, self-service tool.

Launched from a desktop shortcut. PowerShell + WPF — no runtime to install, no dependencies,
works on the stock Windows 10 box it targets.

## 2. Core Elements (make-or-break)

1. **It never destroys work.** No source file, no git-tracked content, no dependency cache that
   costs a re-download. A single false positive kills trust in the tool permanently.
2. **Scan-then-confirm.** Nothing is deleted until findings are shown with sizes and the user
   ticks them and hits Clean. Dry-run shows the exact path list first.
3. **It handles >260-char paths.** The CMake output that fills these drives lives at paths
   `Remove-Item` and `rd` fail on outright. robocopy-mirror-from-empty is the only reliable method.
4. **Honest numbers.** Reported reclaim must match actual free-space delta. A tool that claims
   40 GB and frees 4 is worse than no tool.

## 3. Highest-Leverage Features (ranked, full list)

1. Android/Gradle build output scanner (`android/build`, `android/.cxx` incl. inside node_modules)
2. Package + build cache scanner (gradle version caches, npm/pnpm/bun/yarn, temp dirs, `.next`/`dist`/`.venv`)
3. Cleaner engine — long-path-safe, dry-run, transaction log
4. WPF GUI — drive bars, grouped checkbox findings, progress, live reclaim total
5. Browser + app cache scanner (Chrome/Edge/Brave profiles, on-device models, AI tool caches)
6. Windows system reclaim (recycle bins, Downloads triage, Installer orphans, WinSxS via DISM, big-file finder)
7. node_modules reaper (age-ranked, restore-cost flagged)
8. Duplicate / stale project finder (report-only)
9. Advanced flow — custom roots, size/age thresholds, exclusion list, saved config
10. Desktop shortcut installer
11. Scan history / trend (what regrows fastest)

## 4. MVP Carve-out (Phase 2 scope)

Items 1-10. Item 11 (history/trend) defers to Phase 5.

## 5. MVP Acceptance Criteria

- Scans both drives and reports findings grouped by category with accurate byte counts.
- Every finding carries a Risk level (Safe / Moderate / Advanced) and a plain-English "what breaks
  if I delete this" line.
- Dry-run prints the exact path list without touching disk.
- Clean reclaims within 5% of predicted, measured as `ActualPathBytes` (sum of per-path
  before/after deltas) vs `Predicted`. The whole-drive free-space delta is shown but is explicitly
  NOT the acceptance measure — concurrent writers make it unreliable over a multi-minute clean.
- Duplicate finder: correctly identifies `D:\A` vs `D:\Pulse` as near-identical, reports the
  evidence (% of sampled files matching), and offers no delete action for either.
- Advanced flow: a custom root added in the UI is scanned; a path added to the exclusion list is
  absent from findings; both survive a restart (persisted to `config.json`).
- Junction safety: `tests/Junction.Tests.ps1` green — a junction inside a cleaned tree never loses
  its target's contents.
- Protected paths are provably unreachable: a unit test asserts the guard rejects `.git`,
  `modules-2`, `C:\Windows\System32`, `Program Files`, pagefile/hiberfil, drive roots, and source dirs.
- Handles a >260-char path without error.
- Launches from a desktop shortcut on a machine with no extra software installed.

## 6. Phase 0 assumptions (defaults applied — correct anything wrong)

| Category | Assumed |
|---|---|
| Persona | Single user (Sagar), local admin on one Windows 10 box. No multi-user, no permissions model. |
| Navigation | Single window. Category groups expand/collapse. Advanced behind a toggle, not a separate screen. |
| Empty state | First launch shows drive bars + a Scan button; no findings list until a scan runs. |
| Loading | Determinate progress bar during scan (per-root), spinner on clean with current path label. |
| Errors | Locked/in-use files are skipped and listed in a "couldn't clean" section, never a hard failure. |
| Mobile | N/A — desktop only. |
| Export | Scan results exportable to CSV; every clean writes a timestamped log to `logs/`. |
| Audit log | Every clean run logged: path, bytes, method, result. Retained indefinitely. |
| Pricing/quota | N/A. |
| Scheduling | Out of scope for MVP (user chose scan-then-confirm). Revisit in Phase 5. |
```
