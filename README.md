# Drive Janitor

A zero-install Windows desktop tool that finds and reclaims disk space on `C:\` and `D:\` —
build caches, browser/app caches, dead `node_modules`, and general Windows cruft. Built for a
dev box whose drives fill up from Android/Gradle/React Native build output.

No installer, no dependencies, no runtime to download. Just PowerShell + WPF, both already on
your Windows 10 box.

## What it does

Drive Janitor scans your drives (or any roots you configure), groups what it finds into
categories with sizes, and shows you exactly what it would delete before it deletes anything.
Nothing is ever cleaned without you ticking it and confirming — see **Report-only findings**
below for the one category that can never be auto-cleaned at all.

It never touches:
- Git metadata (`.git`), source directories, or anything inside its own tool folder.
- Downloaded dependency jars (`.gradle\caches\modules-2`).
- Windows system directories, `Program Files`, the pagefile/hiberfil, or drive roots.
- Browser profile data — bookmarks, cookies, history, saved logins.

These are enforced in `modules/Core.psm1`, which every scanner and the cleaner must call before
touching a path — a scanner bug can propose a bad path, but it can never delete one.

## How to run

**GUI (normal use):** run `Install-Shortcut.ps1` once (see below), then use the "Drive Janitor"
shortcut on your Desktop or in the Start Menu. It opens a window with drive-space bars, a
**Scan** button, and a checkbox tree of findings.

**Command line (headless):** from a PowerShell prompt in this folder:

```powershell
.\DriveJanitor.ps1 -CLI            # scan and print a findings table, no GUI
.\DriveJanitor.ps1 -CLI -DryRun    # also print the exact paths that would be cleaned (Safe-risk only), touches nothing
```

`-CLI` never loads the WPF window — useful for scripting or running over SSH/RDP without a
desktop session.

### First-time setup: the shortcut

```powershell
.\Install-Shortcut.ps1
```

Creates (or refreshes) a Desktop and Start Menu shortcut named "Drive Janitor". Safe to re-run
any time — it overwrites the same two shortcuts rather than duplicating them. The shortcut
always launches with `-STA -ExecutionPolicy Bypass`, so it works from a stock Windows 10 box
with no execution-policy changes needed system-wide.

## Risk levels

Every finding is tagged so you know what you're agreeing to before you clean it:

| Risk | Meaning | Pre-ticked in the GUI? |
|---|---|---|
| **Safe** | Regenerates automatically the next time you build or launch the thing that made it. No action needed to restore it. | Yes |
| **Moderate** | Regenerates, but costs something to get back — a re-download, a `npm install` / `pnpm i` / `yarn`, re-opening an app that has to rebuild a cache. | No |
| **Advanced** | Irreversible, or needs your judgment (duplicate project detection, orphaned Windows Installer patches, WinSxS, big files, hibernation file). Never pre-ticked, never auto-selected. | No |

Only **Safe** findings are ticked by default when a scan finishes. You decide about everything
else.

## Report-only findings

Some findings show up so you know they exist, but Drive Janitor will **never offer to clean
them automatically** — no checkbox, no "select all," nothing. These need a real decision, not a
one-click delete:

- **Duplicate / near-identical project folders** — Drive Janitor tells you two folders look
  like copies of each other and shows the evidence (% of sampled files that match), but it's
  your call which one (if either) to keep.
- **Stale projects** (no git remote, untouched 90+ days) — flagged so you notice them, not
  deleted for you.
- **Orphaned Windows Installer patches** — orphan detection isn't reliable enough to trust with
  an automated delete; deleting the wrong one can break repair/uninstall for an installed app.
- **Big files** (>500 MB outside protected paths) and the **hibernation file** — shown with the
  exact command to remove them yourself if you want to.

These findings render without a checkbox in the GUI and are always skipped by the cleaner, even
if you somehow select them.

## Adding a custom root or excluding a path

By default Drive Janitor scans `C:\` and `D:\`. To scan somewhere else, or stop it from
scanning something (e.g. an external drive, a network-mapped folder, a project you don't want
touched):

1. Open the app, click the **Advanced** toggle.
2. **Custom roots** — add any folder path; it's included in the next scan.
3. **Exclusion list** — add any path; it's filtered out of every future scan's findings.
4. Both survive a restart — they're saved to `config.json` in this folder as soon as you change
   them.

To edit `config.json` by hand instead, it's plain JSON:

```json
{
  "Roots": ["C:\\", "D:\\", "E:\\Projects"],
  "MinSizeBytes": 10485760,
  "AgeThresholdDays": 90,
  "Exclusions": ["D:\\Projects\\keep-this-one"],
  "LastScan": null
}
```

If `config.json` is missing or corrupted, Drive Janitor silently falls back to defaults
(`C:\`, `D:\`, no exclusions) rather than failing to start.

## Logs

Every clean run writes a timestamped log to `logs\run-YYYY-MM-DD.log` — what was cleaned,
skipped, or blocked, and why. Logs are kept indefinitely; nothing in this tool deletes its own
logs.
