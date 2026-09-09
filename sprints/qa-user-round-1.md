# QA-User — mvp Round 1

## Variant: ui (native WPF desktop app) — CLI variant also exercised as a secondary surface
## Depth: deep (items 12-17 run in this Round 1, not deferred)

## Environment note (read this first — it shaped the whole test method)

Two conditions materially affected how this round was run, both disclosed here for the integrity
of the findings below:

1. **The interactive session was screen-locked for the entire test (`LogonUI.exe` running, session
   state "Active" not "Disc").** `CopyFromScreen` returned either the Windows lock-screen wallpaper
   or a blank/invalid-handle bitmap for every capture attempt. I could not obtain a single real
   pixel screenshot of the app. I disclose this explicitly per the integrity rule against claiming
   a screenshot was captured when it wasn't. I pivoted to **UI Automation** (`System.Windows.Automation`,
   the Windows-native equivalent of a Playwright accessibility-tree snapshot) to read control types,
   names, enabled/offscreen state, and bound values directly from the running app — which is how
   every structural claim below (button states, panel visibility, field values) was actually verified.
   Anything that requires actual pixels (font rendering, exact spacing, color/contrast) could **not**
   be verified this round and is called out as such, not silently assumed.
2. **This machine had at least one other agent (almost certainly QA-Backend) exercising Drive
   Janitor concurrently** — confirmed via `Get-CimInstance Win32_Process`, which repeatedly showed
   `launch-gui-test.ps1` / `full-flow.ps1` scripts I never wrote, launching against their own PIDs,
   and via the shared `logs/run-2026-08-24.log` containing scan/clean activity (fixture paths like
   `dj-junction-test-*`, `dj-qa-e2e-*`) that isn't mine. I actively controlled for this: every finding
   below that could plausibly be confused with cross-agent noise (e.g. an early "double window"
   observation, an early "crash on save" hypothesis) was **re-tested in isolation with my own
   uniquely-tracked PID** before being written up, and two early false leads were explicitly ruled
   out rather than reported (see "Ruled out" note under Practical Issues).

---

## Mental framework walkthrough

### Q1: Can I do the thing the brief said?
- **Verdict: FAIL.**
- The brief's core workflow (§1/§2/§6): Scan → see findings with sizes/risk → tick → Dry-run →
  Clean. In the GUI — the tool's actual declared surface ("A zero-install Windows desktop app...
  PowerShell + WPF") — **the app crashes every single time "Scan" is clicked**, before findings are
  ever displayed. Reproduced 3/3 times: twice against my own safe fixture custom root, once against
  the real default `C:\`, `D:\` roots (untouched Advanced panel, exactly what a first-time user
  would click). Each crash is precisely time-correlated (within 1 second) to my own script's
  click-timestamp and logged by the app itself:
  `[ERROR] GUI load failed: Exception calling "ShowDialog" with "0" argument(s): "The property
  'Count' cannot be found on this object. Verify that the property exists."`
  I never once reached the point where a checkbox, Dry-run output, or Clean action was reachable in
  the GUI. CLI mode (`-CLI -DryRun`) does complete a scan successfully (492 findings, 51.15 GB,
  668s), but CLI has no Clean capability at all (confirmed via `Get-Help` — only `-CLI` and
  `-DryRun` parameters exist), so the full workflow cannot be completed through either surface.

### Q2: First-login empty state
- **Verdict: PASS (structurally; visual polish unverified — see Environment note).**
- Fresh instance (no prior `config.json`), UI Automation snapshot on first render:
  - `Scan` button enabled; `Dry run` and `Clean` both correctly **disabled**.
  - Center-window text: *"Click Scan to find reclaimable space on C: and D:."* — clear, friendly,
    on-brief.
  - Drive info shown as text: `C:   22.55 GB free of 154.64 GB   (14.6% free)` /
    `D:   38.47 GB free of 68.36 GB   (56.3% free)`.
  - `Selected: 0 B` footer initialized correctly.
  - Advanced panel correctly collapsed (`offscreen=True` on every one of its controls) until toggled.
- Could not confirm whether the "drive bars" mentioned in Phase-0 assumptions render as an actual
  graphical bar or are text-only — UI Automation only exposed text labels, no bar-shaped control
  under those two `Text` elements. See owner-opinion note.

### Q3: What breaks with weird/boundary input?
- **Verdict: Mixed.**
- Saving the Advanced panel (without ever clicking Scan) tolerated everything I threw at it without
  crashing: a nonexistent custom root (`Z:\DoesNotExist\NowhereAtAll12345`), a path with spaces
  (`...\Fake Project With Spaces`), an emoji/unicode exclusion path, a whitespace-only exclusion
  line, non-numeric `Min size (MB)` = `"abc"`, negative `Age threshold` = `"-1"` — all accepted,
  status showed "Settings saved", process stayed alive and `Responding=True` in every one of these
  save-only tests.
- However: **none of this matters for the actual scan-then-confirm flow, because clicking Scan
  crashes regardless of what's in these fields** — including with the untouched defaults. So
  boundary-input robustness at Save time is real but moot; the thing that needed to survive boundary
  input (a scan against a weird root) never got the chance to prove itself either way.
- Numeric field validation gap: `"abc"` in Min Size (MB) is accepted with zero feedback — see
  Practical Issues.

### Q4: Does the output match what was generated?
- **Verdict: Partial / mostly blocked.**
- CLI's numbers are internally plausible: top-line "492 finding(s), 51.15 GB total", and the
  Safe-risk dry-run subset "Would reclaim: 6.68 GB across 4 selected finding(s)" — 6.68 GB is a
  sensible subset of 51.15 GB (only Safe-risk categories), and roughly matches summing the two
  Safe-risk category rows visible in the table (Android Build 3.65 GB + Build Output 2.83 GB =
  6.48 GB, close enough to 6.68 GB that other small Safe items likely fill the gap).
- Could **not** verify the acceptance criterion that matters most here — "Clean reclaims within 5%
  of predicted" — because Clean is unreachable in the GUI (crash) and absent from CLI. This is
  reported as unverified, not as passing.
- Duplicate finder produces **zero output** system-wide despite the exact fixture the brief names
  (`D:\A` vs `D:\Pulse`) existing for real on this machine — see Practical Issues #2.

### Q5: Intuition bucket
- Scan is genuinely slow (confirmed by my own measurement, see Practical Issues #7) — for a tool
  whose whole pitch is "repeatable, self-service" quick disk triage, an 11-25 minute wait before you
  see anything is a real tax on the experience, independent of the crash.
- The Advanced panel's Custom Roots / Exclusions boxes are small (~60px tall multi-line `TextBox`es)
  for what's meant to hold multiple full Windows paths — usable but cramped once you have more than
  2-3 entries. Owner-opinion, not a defect.
- I'd have expected a visible "scan failed" error dialog or at least a status-bar message when the
  GUI crashes — instead the window just vanishes with no user-facing explanation at all, only a
  line in a log file the user will never think to open. Even a full crash surviving gracefully with
  "something went wrong, see logs/" would substantially change how this feels to hit.

### Q6: Does this feel like another org tool?
- **N/A — not applicable.** This is a native Win32/WPF desktop application, not a browser-based tool
  in the org's web design system (electric-blue-on-navy stage, Tailwind tokens, etc. per
  `org-tool-conventions` §6 do not apply to a WPF window). I did not force a verdict against a
  web-app rubric that doesn't transfer. Structurally (via UI Automation) the layout is a
  conventional native Windows form — two action rows, a findings area, a collapsible Advanced
  section — which is appropriate for the stated persona (a single local admin developer), not a
  criticism.

### Q7: What's good?
- See Positives bucket below.

### Q8: Would I use this tomorrow?
- **No — not in its current state.** The single biggest blocker: the GUI, which is the tool's
  actual declared product surface, cannot complete one full scan without crashing. That is
  disqualifying on its own, independent of every other finding. Even setting that aside, I could not
  find a single currently-working path (automated test suite, or live GUI/CLI use) that actually
  proves Core Element #1 ("it never destroys work") holds today — the named Pester suite discovers
  zero tests, and the GUI crash blocks ever reaching Clean to prove it live. I would not point this
  at my own C:/D: drives yet.

---

## Practical issues: reproducible bugs

1. **[critical] GUI crashes on every Scan click — Core Element #2 ("Scan-then-confirm... findings
   are shown") and the entire Q1 workflow are broken on the tool's declared primary surface.**
   Repro: launch `DriveJanitor.ps1` (GUI, `-STA`), click `Scan` (custom fixture root or untouched
   default `C:\`/`D:\` roots — doesn't matter which). Process exits within 1-55 seconds of the
   click, `TxtStatus` was still showing `"Scanning..."` and the window was still
   `Process.Responding = True` right up to the moment it vanished. App's own log, 3-for-3 exact
   time-correlated to my click timestamps:
   `19:37:27 [ERROR] GUI load failed: Exception calling "ShowDialog" with "0" argument(s): "The
   property 'Count' cannot be found on this object. Verify that the property exists."`
   (repeated verbatim at `19:38:18` and `19:40:02`, matching my 2nd and 3rd attempts exactly).
   CLI mode does **not** hit this — a full CLI `-DryRun` scan of the real `C:\`+`D:\` completed
   cleanly (492 findings, 668s, no crash) — so the underlying scan engine substantially works; this
   is specifically a GUI-results-rendering-path defect. What survives despite this: nothing in the
   GUI workflow survives it — this is as close to total as a finding gets for this surface.

2. **[critical] Duplicate/stale-project finder is completely non-functional — breaks the explicit
   MVP Acceptance Criterion naming this exact fixture.** §5 states: *"Duplicate finder: correctly
   identifies `D:\A` vs `D:\Pulse` as near-identical..."* — both directories exist for real on this
   machine (verified: `D:\A\.npmrc`, `D:\A\artifacts\...`, `D:\Pulse\.npmrc`,
   `D:\Pulse\artifacts\...`). Every scan I ran or observed in the shared log throws, twice
   independently confirmed: `[ERROR] duplicate finder failed: The property 'Name' cannot be found on
   this object. Verify that the property exists.` — immediately followed by
   `[INFO] Invoke-ProjectScan done: N findings` (the scan continues, so this doesn't crash the CLI
   scan itself, unlike #1). My own full CLI scan output (2554 lines, 492 findings) contains **zero**
   occurrences of the word "duplicate" anywhere. What survives: the rest of the scan (492 other
   findings) is unaffected — this is scoped to the one feature, but that feature is a named
   acceptance criterion and it produces nothing at all, silently.

3. **[critical] Advanced settings persistence is broken for 3 of 4 fields — breaks the MVP
   Acceptance Criterion "a path added to the exclusion list is absent from findings... both
   [custom root and exclusion] survive a restart (persisted to config.json)."**
   Repro (run twice, second time with explicit `SetFocus()`/blur on each field before Save to rule
   out a LostFocus-binding artifact — same result both times): launch → toggle Advanced → set
   Custom Roots, Exclusions, Min Size (MB)=7, Age (days)=3 → confirmed all 4 values correctly
   present in the UI immediately before clicking Save → click Save (`"Settings saved"` shown) →
   close window cleanly (`WindowPattern.Close()`) → relaunch fresh instance → toggle Advanced →
   read back values. Result: **Custom Roots persisted correctly both times; Exclusions, Min Size,
   and Age Threshold all reverted to blank/`0` both times**, despite the identical "Settings saved"
   confirmation being shown for all four together. `config.json` does exist and does get rewritten
   on Save (262 bytes, timestamp matches), consistent with only a subset of fields actually being
   serialized. What survives: Custom Roots persistence works; the mechanism exists, it's just
   incomplete.

4. **[critical] The officially-named safety-proof mechanism for Core Element #1 does not execute —
   zero tests discovered in any of the 4 Pester files, under 2 different Pester major versions.**
   `tests/Guard.Tests.ps1`, `Junction.Tests.ps1`, `Sizing.Tests.ps1`, `Integration.Tests.ps1` — ran
   each individually via `Invoke-Pester`. Under the Windows-stock Pester 3.4.0 (what a genuinely
   fresh Windows 10 box actually has, per the brief's own "no extra software installed" acceptance
   criterion): 0/0/0/0 discovered across all four. I then installed Pester 6.1.0 fresh (not a
   zero-friction operation either — required manually installing the NuGet provider and trusting
   PSGallery first; a first `Install-Module` attempt failed outright on an interactive prompt) and
   re-ran: **still 0 tests discovered in all 4 files**, no error thrown, `Result: Passed` (a false
   "green" — nothing was actually asserted). `Integration.Tests.ps1` took 461.92s to discover 0
   tests, meaning real work happens during "discovery" but produces no actual `Describe`/`It`
   results either version. Combined with #1 (GUI crash blocks ever reaching Clean live), there is
   currently **no working path — automated or manual — that proves the protected-path guard or
   junction-safety logic holds**, for the one property the brief calls the single most important
   thing about this tool ("A single false positive kills trust in the tool permanently"). I did find
   *indirect, encouraging* evidence in the shared log from another agent's run — real
   `[BLOCK] defense-in-depth refused: ...__pycache__` / `...ndk\...\build` entries, and
   `[SKIP] unlinked 2 junction(s) ... before mirror` / `[BLOCK] reparse point, refused: ...` entries
   — suggesting the underlying guard logic is present and firing in practice. That's reassuring but
   it is third-party/incidental, not something I verified myself, and it doesn't substitute for a
   working test suite or a live Clean I could run.

5. **[critical, unconfirmed — needs owner/build-agent verification before this ships] The Safe-risk
   dry-run path list ends with two bare, unqualified container paths:**
   `C:\Users\VA-007\AppData\Local\Temp` and `C:\Windows\Temp`, printed exactly like every other
   "would delete" entry in the same list, with no visible age filter, wildcard, or file-count
   annotation distinguishing them from a literal whole-folder target. I deliberately did **not**
   run a real Clean against these (dangerous_actions/§0-B forbid it), so I cannot confirm whether
   the actual delete operation targets only old files inside these folders (safe, and plausibly what
   was intended — "Temp files >X days" is a documented category) or the containing folder itself
   (which would be catastrophic — `C:\Windows\Temp` is relied on by running Windows processes).
   Flagging critical rather than dismissing it because: (a) the AC requires dry-run to print the
   "exact" path that would be deleted — if the real target is "old files inside," printing the bare
   folder is a transparency failure even in the good-case interpretation; (b) if it's the bad-case
   interpretation, it is a direct Core Element #1 violation. This needs a direct answer from
   whoever owns the Cleaner engine before I would consider this drive-safe.

6. **[minor] No input validation on numeric Advanced fields.** `Min size (MB)` accepts the literal
   text `"abc"`; `Age threshold (days)` accepts `"-1"`. Both are saved with the same generic
   `"Settings saved"` status as valid input — no red-border, no error text, no coercion to `0`
   shown in the UI. What still works: the rest of the Save flow (Custom Roots, in particular)
   functions fine regardless; this doesn't block the workflow, it just means an invalid value
   silently gets treated as *something* the next time a scan runs (untested, since Scan always
   crashes — see #1).

7. **[minor] Full scan is slow — confirmed, not just previously-reported.** My own timed CLI
   `-DryRun` run against the real `C:\`+`D:\`: **668 seconds (~11.1 minutes)**, under acknowledged
   concurrent load from other agents also scanning the same disks during this window (see
   Environment note) — so this number is likely somewhat inflated versus a clean single-user run,
   but it's the same order of magnitude as the previously-reported ~25 minutes, not a different
   ballpark. Either way: multiple minutes before a user sees anything is a real cost against the
   tool's "repeatable, self-service, quick check" pitch. Doesn't block the workflow (it does
   complete via CLI) — flagged as UX weight, not breakage.

8. **[minor] No single-instance guard.** Multiple `DriveJanitor.ps1` GUI processes can run
   concurrently with no warning (observed directly — my own instances and a concurrent agent's
   instances coexisted simultaneously with no conflict message). Given `ownership: personal` /
   single local-admin user per brief §6, this is low priority, but nothing currently stops two
   Clean runs from racing against overlapping roots if it ever happened.

**Ruled out (explicitly, for the record — not reported as bugs):**
- *"Launching the shortcut opens two windows."* My first observation (two "Drive Janitor" windows
  ~10s apart) turned out to be my own launch plus a concurrent agent's independent launch in the
  same shared environment, not a double-launch from a single click — confirmed by finding an
  unrelated `launch-gui-test.ps1` script (not mine) driving one of the two PIDs, and by every
  subsequent single-launch test producing exactly one window/one PID.
- *"Setting Min Size = 'abc' crashes the app on Save."* First observation looked deterministic, but
  a clean re-test of the exact same sequence (fresh launch → toggle → set `"abc"` → Save) survived
  fine on the 2nd and 3rd attempts, and a control test (Save with zero edits) also died on its own a
  few minutes later while completely idle — meaning **all** instances in this environment were
  being torn down periodically regardless of what I did to them, almost certainly by a concurrent
  agent's own test-round cleanup. Not attributed to Drive Janitor.

---

## Positives: what's good

- Desktop shortcut (`C:\Users\VA-007\Desktop\Drive Janitor.lnk`) launches correctly with the exact
  expected target/args (`powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File
  ...\DriveJanitor.ps1`), no extra runtime needed — the "launches from a desktop shortcut on a
  machine with no extra software installed" acceptance criterion is mechanically satisfied.
- First-run empty state is clear, friendly, and correctly gated (Scan enabled, Dry run/Clean
  disabled until there's something to act on) — good scan-then-confirm discipline at the button
  level, verified structurally.
- Advanced panel is properly hidden by default and expands/collapses cleanly on toggle — every
  control genuinely goes `offscreen=True`↔`False`, not just visually hidden with hit-testing left on.
- **The GUI never hangs.** `Process.Responding` stayed `True` through every single scan attempt,
  polled repeatedly up to 50+ seconds in — when this app fails, it fails by crashing, not by
  freezing the window. That's a real, verified answer to the specific "does the GUI freeze" concern
  this round was asked to check.
- CLI mode is solid on its own terms: a full `C:\`+`D:\` scan completed without error (492
  findings, 51.15 GB total, categorized table with Size/Risk/Action, plus an exact dry-run path
  list for the Safe-risk subset) — the underlying scan engine clearly does real, substantial work
  correctly, independent of the GUI-layer crash.
- Findings taxonomy is genuinely well-matched to the stated persona: Android Build, Browser Cache,
  Package Manager Cache, AI/Dev Tool Cache, `Projects: node_modules` (with idle-day age shown per
  entry), `Projects: Stale`, Downloads — with sensible Risk tiers (Safe/Moderate/Advanced) and
  Action verbs (Delete/Empty/Report). This is a thoughtful category design, not a generic disk
  scanner reskin.
- Custom Roots value in Advanced correctly persists across a full app restart (confirmed twice) —
  the persistence *mechanism* clearly works end-to-end for at least one field.
- Independent (third-party, not self-verified) evidence in the shared log suggests the
  defense-in-depth protected-path guard and junction-unlink-before-mirror logic are both present and
  actively firing in real runs.

---

## Coverage of deep-pass items 12-17 (qa_depth: deep, run in this Round 1)

- **#12 Settings walk:** done — every Advanced field (Custom Roots, Exclusions, Min Size, Age
  Threshold) was set, saved, and restart-verified; see Practical Issue #3 for results.
- **#13 Concurrent-session race testing:** not applicable in the brief's own sense (single-user,
  `ownership: personal`, no multi-user model) — but I *did* passively observe multiple concurrent
  Drive Janitor instances coexisting in this shared test environment with no conflict (see Practical
  Issue #8).
- **#14 Full boundary-input pass:** done on every Advanced field (nonexistent root, spaced path,
  empty/whitespace exclusion, emoji/unicode exclusion, non-numeric size, negative age) — see Q3 and
  Practical Issue #6.
- **#15 Loading + error state screenshots:** attempted, blocked by the environment screen-lock (see
  Environment note) — captured via UI Automation instead (status text `"Scanning..."`, progress bar
  element present, `TxtCurrentPath` element present) rather than pixels. No genuine "findings"
  loaded state was ever reachable due to Practical Issue #1.
- **#16 Multiple multimodal artifacts:** not applicable — this is not a media-generation tool.
- **#17 Mobile breakpoint pass:** not applicable — desktop-only per brief §6.

---

## Overall verdict

**CRITICAL_ISSUES**

## If issues: required fixes for main Claude

1. **Fix the GUI crash on Scan (Practical Issue #1) — this is the blocker.** Nothing else in this
   report can be re-verified through the GUI until a scan can complete and show findings. Given the
   error text (`"The property 'Count' cannot be found on this object"` inside a `ShowDialog` call)
   and that it correlates with the duplicate-finder failure happening on every scan, I'd start by
   checking whether the duplicate-finder's failure (#2) is leaving a `$null`/malformed collection
   that the GUI results path then references without a null-check.
2. Fix the duplicate finder (Practical Issue #2) — it should be independently testable against the
   real `D:\A` / `D:\Pulse` fixture that's sitting on this machine specifically for that purpose.
3. Fix Advanced-settings persistence for Exclusions / Min Size / Age Threshold (Practical Issue #3)
   — Custom Roots proves the mechanism works; the other three fields need to go through the same
   path.
4. Get the Pester suite actually discovering and running its tests (Practical Issue #4) — right now
   "green" means nothing, on all four files, on two Pester versions.
5. Get a direct answer on what the bare `C:\Users\...\Temp` / `C:\Windows\Temp` dry-run entries
   actually target (Practical Issue #5) before this tool touches a real drive.
6. Once #1 is fixed, this round needs a follow-up pass that actually reaches Clean — on my fixture,
   never on real C:/D: — to verify the junction-safety and protected-path guarantees live, since
   neither the test suite nor this round's GUI testing could do that this time.
