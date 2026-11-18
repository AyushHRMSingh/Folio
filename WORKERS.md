# Folio — instructions for worker sessions

Read this file and `CLAUDE.md` before touching code. This file replaces the old audit files
(`UX_ISSUES.md`, `AUDIT-WAVE2.md`, both in git history at commit `6970de4` if you need the original detail).
Keep it current: when you finish or change an item, update its row in **Status** at the bottom.

---

## 1. What Folio is (and isn't)

A simple, fast, stable macOS manga/webtoon reader; a Tachimanga alternative. Webtoon reading is the primary mode.
Mac first; iPad/iPhone is parked (`PORTING.md`). Feature ideas live in `FEATURES.md`; parity checklist in `PARITY.md`.
**No new features until "Next steps" 1–4 below are done.**

## 2. The owner's decisions (binding)

- **D1. Nested pages are fine.** Long screens (Settings first) become a list of sections that each push a subpage,
  with the standard back control.
- **D2. Per-comic reading settings live in a popup.** Mode, continuous scrolling, width, gap, background, crop, tap
  zones, double page are never permanent buttons. One panel, opened from the reader's ⚙ (and `S`) and from the
  series page "···" → "Reading settings…", scoped to *this comic*, with per-row "reset to default" and
  "Use as default for all comics". Settings › Reader defaults is the same panel editing the global defaults.
- **D3. No counts in the navigation** (no number next to "Library").
- **D4. While reading, nothing on screen but the comic** until summoned (mouse to top/bottom edge, click, `M`).
  No toolbar, no progress line, no page number by default, no permanent dividers or labels at the window edge.
- **Taste rules:** simple; laptop-friendly side margins; no "Load more" buttons (auto-load at list end); nothing
  jumps or overlaps while loading; one control style everywhere; tasteful, quiet UI.

## 3. How to work

1. **One item at a time.** Finish, verify, record, then start the next. Don't leave half-edited code between items.
2. **Core changes are test-first.** For anything in `Sources/FolioCore`, add the failing check to
   `Sources/foliotest/main.swift` first, then fix, then `swift run foliotest` (must print "All checks passed.").
3. **UI changes are snapshot-verified.** Use `Tools/qa.sh` (off-screen, throwaway HOME). After a change, snapshot the
   affected screen *and look at the PNG*. For reader changes also check `qa.sh log` for `MOVED` lines, with and
   without `FOLIO_DEBUG_DELAY=1.5`.
4. **Never touch the owner's real data.** Never run against `~/Library/Application Support/Folio` or `FolioEngine`
   except read-only; use the harness HOME or a test HOME. Before any change to loading/saving `library.json`, test
   it against a *copy* of a real-shaped file.
5. **Persistence rule:** every persisted field decodes tolerantly (`decodeIfPresent` + default, unknown enum →
   default). The key-drop test in `foliotest` must keep passing; extend it for new models/fields.
6. **Status words mean exactly this:**
   - **Done** — built, tests pass, and the exact state/interaction was seen working (snapshot, log, or test output).
   - **Done (unchecked)** — built and compiles, tests pass, but the interaction wasn't exercised. Say why.
   - **Partial** — some of the fix; say what's missing.
   - Never write Done for something you only edited.
7. **Don't commit.** The owner commits. Don't push, don't create branches unless asked.
8. **Report** at the end of a work block: what's Done / unchecked / not started, with evidence, in plain words.
9. **When the harness can't reach something**, add a debug-hook command for it (see step 5 of Next steps) rather than
   guessing.

## 4. Next steps (in order)

### Step 1 — Finish and verify the in-flight work
- [ ] Engine lifecycle test on the rebuilt code (password via file, restart after Java dies, cache wipe on start).
- [ ] E1 download path against a real download into a *test* HOME (resume after interrupt; offline; bad status).
- [ ] U1 (title bar stays transparent after closing the reader) and U4 (window min size 760×520 holds at runtime):
      build, snapshot library/recents/sources after reading once, and try `size:560x420`.
- [ ] F6 rapid chapter jumps: two quick `cmd:next` with `FOLIO_DEBUG_DELAY=1.5` must end on the later chapter.
- [ ] Load a copy of a real-shaped `library.json` (old format) with the new tolerant decoding; nothing lost.

### Step 2 — Close the gaps against the owner's decisions
- [ ] **U2 / D2 per-comic reading settings.** Optional per-series overrides in `LibraryEntry` (nil = default,
      tolerant decoding), one panel with two scopes, per-row "differs · reset", "Use as default for all comics",
      `S` shortcut, series "···" → "Reading settings…". Only store an override when it differs from the default
      (today `setMode` always writes one, so later default changes never apply).
- [ ] **U5 / D1 Settings as subpages.** Root list: Appearance · Library · Reader defaults · Updates · Downloads ·
      Privacy · Sources & extensions (Cloudflare, OPDS) · Storage · Backup & import · About, each row with a one-line
      summary of its current value. Remove the tabs.
- [ ] **U3** Paged right-to-left: mirror the whole bottom bar (counter, scrubber, prev/next) consistently.
- [ ] **E2** No Java: a clear panel on the Extensions page ("Extensions need Java 21" + button to the Temurin 21
      installer + "Check again"). Later: download a pinned, SHA-verified JRE like the jar.
- [ ] **U8** No chapter divider above the first loaded chapter; dividers never sit under the traffic lights (D4).
- [ ] **U7** Reader background: `auto` is always dark for reading; webtoon and paged use the same value.
- [ ] **U6 / #25** Reader capsules never cover the page on narrow windows (inset or keep within margins).

### Step 3 — One consistency pass (design system, then migrate)
First add shared building blocks to `Theme.swift` (or `Sources/FolioApp/Components/`):
type scale (title / section / body / meta / label; monospace only for numbers and metadata) ·
`PageHeader` (title + count + right-side tools) · `ToolMenu` (the Library header's menu-button style) ·
`EmptyState` (keeps the page header, one style) · `SettingsRow` (label, hint, control; system-style toggles) ·
`Panel` (popover/sheet container) · `BackLink`.
Then move every screen onto them and delete the one-off styles. This covers:
- [ ] #34 type scale (no literal `.system(size:)` left outside Theme).
- [ ] U12 toolbar styles (series chapter bar, local browse, extensions, settings, sources all match Library).
- [ ] #21 restyle `CategoriesSheet`, `AssignCategoriesSheet`, `MigrateSheet`.
- [ ] #23 Browse Newest/Popular as a segmented control; filters/settings as `ToolMenu`.
- [ ] U14 chapter picker: chevron on the title pill, Theme styling.
- [ ] U16 one empty-state style everywhere; reword "Better start reading."
- [ ] U9 cover placeholder initials never wrap; U10 title "Library" (no superscript next to the "All n" pill);
      U11 header doesn't shift when a filter turns on; U13 series page (save button size, hide Download for local,
      drop duplicate chapter-number column, align date column); U15 cap Recent row width at 940.
- [ ] #14 right-click a category pill → Rename / Delete.
- [ ] #17 series "···": Reading settings… / Categories… / Mark all / Migrate / WebView, grouped with dividers.

### Step 4 — Structural cleanup (no behaviour change; tests and harness are the safety net)
- [ ] Split `Library.swift` (~1050 lines) into Settings, DownloadQueue, Storage, Backup (+ core state).
- [ ] Split `Engine.swift` into Launcher, Client, ExtensionSource.
- [ ] Move views out of `Reader.swift` (model stays; views to `ReaderViews.swift`).
- [ ] Make `ExtensionEngine` an actor injected into `Library`; the app talks to `Library`/`Source`, never
      `ExtensionEngine.shared` or `as? ExtensionSource` (S7). Replace single callback slots
      (`Images.shared.onAspect`, `onStateChange`) with per-subscriber observation (S8).
- [ ] Browse and Extensions become real `NavigationStack` pushes (#3), so back/Esc/⌘[ behave the same everywhere.
- [ ] Turn on Swift 6 strict concurrency per target once the above lands; fix what it finds.

### Step 5 — Make the unchecked half testable, then ask for audit wave 3
Add debug-hook commands (document them in `CLAUDE.md`):
`fullscreen:on|off` · `settings:<subpage>` · `key:<char>` (sends a key to the focused view — for Esc order and
shortcuts) · `gsearch:<q>` that drives the real search field · `popover-dump` (logs the open popover's view tree) ·
`hover:<x,y>` if feasible.
Then verify and record: popovers (View/Filter/Sort, reader settings, chapter picker, queue), full-screen reader,
Esc order, menu bar items, auto-hide timing, chapter hover actions and multi-select, category/migrate sheets,
light mode, compact/list modes. Real extension source + real downloads once E2 is in.

### Step 6 — Release hygiene (before any build is shared)
- [ ] `DebugHook` behind `#if DEBUG` (S9).
- [ ] OPDS passwords in the Keychain, and not in backups (S1).
- [ ] Incognito writes nothing: no aspect ratios, page URLs, or `track()` entries (S3).
- [ ] Engine extras: E4 cache counted/cleared (verify), E5 engine jobs off (verify), E6 no launch download (verify).
- [ ] Before bumping the Suwayomi pin (E7): cookie store on `folioLocal` (CSRF for multipart restore), move off
      BASIC_AUTH, re-test page/thumbnail/icon routes and Tachiyomi/Tachimanga import.
- [ ] `LICENSE` + `NOTICE` (Suwayomi MPL-2.0; OpenJDK GPLv2+CE if a JRE is ever bundled).
- [ ] Developer ID signing, hardened runtime, notarization in `install.sh`; drop `NSAllowsArbitraryLoads` if possible;
      consider `sandbox-exec` for the Java process (S4).
- [ ] Small: `importLocal` off the main thread; `runScheduledUpdate` only stamps on success; `setCategories` dedupes.

---

## 5. Status

| Item | Status | Evidence / notes |
|---|---|---|
| F1 library can't be wiped by a bad entry; corrupt-file alert; `.bak` rotation | Done | foliotest key-drop (148 keys) |
| F2 reopen lands on the saved page | Done | harness, 5× fast and with 1.5 s delay |
| F3 `]` doesn't mark skipped chapters read | Done | harness |
| F4 "All Unread" skips read chapters | Done | foliotest |
| F5 restore keeps downloaded flags | Done | foliotest |
| F6 rapid chapter-jump race | Done (unchecked) | not raced in the harness — Step 1 |
| F7 Cancel all stops running downloads | Done | foliotest |
| F8 retried downloads start from an empty folder | Done | foliotest; complete chapters return early |
| E1 resumable engine download, clear errors | Done (unchecked) | Step 1 |
| E2 Java missing panel | Not started | Step 2 |
| E3 restart after Java dies | Done (unchecked) | Step 1 |
| E4 engine cache counted/cleared/wiped | Done (unchecked) | Step 1/6 |
| E5 engine's own update/backup jobs off | Done (unchecked) | Step 6 |
| E6 no launch download, old jars removed | Done (unchecked) | Step 6 |
| S2 engine password not on the command line | Done (unchecked) | Step 1 |
| S6 quit waits ≤ 2 s | Done (unchecked) | |
| U1 title bar after reading | Partial (edited, not built) | Step 1 |
| U4 window minimum size | Partial (edited, not built) | Step 1 |
| U2 / D2 per-comic settings | Not started | Step 2 |
| U3 RTL bottom bar | Not started | Step 2 |
| U5 / D1 settings subpages | Not started | Step 2 |
| Step 3 consistency pass | Not started | |
| Step 4 structural cleanup | Not started | |
| Step 5 harness hooks + wave 3 | Not started | |
| Step 6 release hygiene | Not started | |
