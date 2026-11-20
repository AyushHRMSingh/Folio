# Folio — instructions for worker sessions

Read this file and `CLAUDE.md` before touching code. This file replaces the old audit files
(`UX_ISSUES.md`, `AUDIT-WAVE2.md`, both removed; recover them from git history if needed).
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
- [ ] **Extensions disclaimer (owner request).** Before the first extension repo can be added, show a one-time
      notice the user must accept: they alone are responsible for any content they add, import or read through
      Folio; Folio ships no content and no repos; Folio does not condone reading copyrighted material without paying
      for it — support the creators and official releases. Store the acceptance (with date) in settings; show the
      same text again in Settings › Sources & extensions and in About. Also add it to `README.md`.
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
| F6 rapid chapter-jump race | Done (unchecked) | not raced in the harness |
| F7 Cancel all stops running downloads | Done | foliotest |
| F8 retried downloads start from an empty folder | Done | foliotest; complete chapters return early |
| E1 resumable engine download, clear errors | Done (unchecked) | code-read: Range/206 resume, 416 retry, status-specific errors, size + SHA-256 before move. Not run (runtimeDir ignores HOME, so a test would touch the real FolioEngine folder — fix that first) |
| E2 Java missing panel | Done | Extensions shows an install panel (Temurin 21 link + Check again) instead of an error; `FOLIO_DEBUG_NO_JAVA=1` snapshot. Bundled JRE: not started |
| E3 restart after Java dies | Done | `foliotest --engine` kills Java; next call restarts |
| E4 engine cache counted/cleared/wiped | Done | wipe on start verified; `cacheSize()` code-read only |
| E5 engine's own update/backup jobs off | Done | `ps` shows globalUpdateInterval=0, backupInterval=0 |
| E6 no launch download, old jars removed | Done (unchecked) | code-read |
| S2 engine password not on the command line | Done | `ps` shows only `@engine.args` (0600, deleted after start) |
| S6 quit waits ≤ 2 s | Done | `foliotest --engine`: stop < 3 s, no leftover processes |
| U1 title bar after reading | Done | snapshot after closing the reader: no gray band |
| U4 window minimum size | Done | `host.sizingOptions = [.minSize]`; `state` reports contentMin 760×548 before and after reading |
| U2 / D2 per-comic settings | Done | `ReaderOverrides` on `LibraryEntry`, `ReadingSettingsPanel` (reader ⚙ / `S`, series ··· → Reading Settings…, Settings › Reader defaults); 10 foliotest checks; harness: width on one comic left the default and other comics alone. Popover/sheet contents not snapshotted |
| U3 RTL bottom bar | Done | snapshot: page 1 + previous chapter on the right, under the scrubber's start |
| U5 / D1 settings subpages | Done | root list with summaries → pushed pages; `settings:<page>` debug command; snapshots of root, reader, sources, back |
| Step 3 consistency pass | Mostly done | switches, type scale (`Font.folio*`), TextAction/ToolMenuLabel, library header (U10/U11), category rename/delete (#14), sheets restyled (#21), MigrateSheet, Browse segmented control (#23), cover initials (U9), Recent width + empty state (U15/U16), series page (U13/#17), reader divider/auto background/chapter picker (U7/U8/U14), panels (Filter/Prefs/Web/PageMenu). Left: migrate remaining literal font sizes to `Font.folio*`; U6 left capsule now fits the margin at 800×560 (drops chapter name, truncates title) but the right tools capsule still touches the page edge; sheets/popovers not seen on screen |
| Step 4 structural cleanup | Partly done | Engine.swift → Engine/EngineLauncher/EngineClient/ExtensionSource; Library.swift → Library/Settings/LibraryDownloads/LibraryStorage/LibraryBackup; Reader.swift → Reader/ReaderView/ReaderChrome/ReaderStripViews; Browse/Extensions are real NavigationStack pushes (#3). Left: ExtensionEngine as an injected actor (S7/S8), Swift 6 strict concurrency, remove unreachable sidebar special-case in `AppDelegate.goBack` |
| Step 5 harness hooks + wave 3 | Not started | |
| Step 6 release hygiene | Not started | |
| Library "Up next" row | Done | snapshot after reading partway; menu/search-hiding not seen |
| Menu bar (#35) | Done (unchecked) | View menu: Show Reader Controls (M), Reading Settings… (S), Chapters… (C), zoom ⌘= ⌘- ⌘0; QA instance has no menu bar |
| importLocal off the main thread | Done (unchecked) | copies in a detached task with "Importing i of n…" |
| Scheduled update stamps only on success | Done | `Library.runScheduledRefresh()`; core-tested except the all-failed case |
| S3 incognito leaves no traces | Done | foliotest: no aspects, no page URLs, no history entry |
| S1 OPDS passwords | Owner decision: no Keychain | passwords stay in library.json (user-only file) but are left out of backups |
| NOTICE.md + README | Done | no LICENSE yet — owner to choose |
| Light-mode pass | Partial | library, settings root, reader fine. To fix: off-state MonoSwitch knob and slider thumbs low-contrast on light; series-page mono metadata (source line, dates, chapter-bar tools) too faint. Reader chrome/popovers are intentionally dark. No debug key sets appearance yet (add `set:appearance=light`) |
| Engine runtimeDir honours HOME | Done | built from `Paths.home`; tests no longer touch the real FolioEngine folder |
| Series details (owner request) | Done | details fetched on open (saved or not); byline author · art by artist · status · source; full description; tag chips (right-click → search all sources); chapters / last update / scanlation facts; all Tachiyomi statuses (licensed, publishing finished, cancelled, on hiatus). Seen with a local details.json; not yet seen with a real extension source |
| Series ··· before saving (owner request) | Done | Search All Sources for title, Reading Settings, WebView, Copy Link; save is an icon-only bookmark toggle |
| WebView (owner request) | Done | separate "Folio Web" window: back/forward/reload-stop, editable address, progress line, copy link, open in browser; persistent Folio-only website data + Settings › Privacy clear; `web:<url>` debug command. Left: hand cookies to the engine (likely `Engine/settings/cookie_store.xml` while the engine is stopped; needs matching user agent) and a "Website" button on Browse (engine exposes no source base URL) |
| Blacklist (owner request) | Done | series ··· → Blacklist… (confirm) or right-click a Browse cover; hidden by id AND by normalised title on every source; removed from library/history (downloads deleted); filtered from Browse, global search, library, Recent; Settings › Library lists them with Remove. 6 foliotest checks; harness: blacklisted series gone from Browse |
| index.pb repo links (owner request) | Done | engine accepts `…/raw/repo/index.pb` (Keiyoushi, 1714 extensions via `repo-add:`); hints updated |
| Cloudflare: user verifies (owner request) | Done (needs a real-site check) | Folio runs a FlareSolverr-compatible helper on 127.0.0.1 (`CloudflareSolver.swift`); the engine calls it on a challenge, Folio opens a "Verify you're human" window on that page, the user completes it, cookies + Folio Web's UA go back to the engine. One window per site; reuses a recent pass once silently. Engine started with timeout 240 s, response fallback off. Net layer no longer retries Cloudflare blocks; page tiles show the reason (Cloudflare / no connection / timed out / site error). Protocol + window verified in harness with a fake request; not yet seen against a live Cloudflare site |
| Cloudflare: no block pages, no spam (owner request) | Done (harness-tested) | `CloudflareSolver` first loads the address in an invisible window: a hard block ("you have been blocked", 1020…) never shows a window and pauses that site 15 min with one notice; a page that just loads is handed over silently; only a real human check is shown, naming the source being read ("X's image server (host)") and sending its site as Referer. |
| Request hygiene (owner request) | Done (core-tested) | Engine image requests are never retried by Folio (the engine already went to the site). 429 is never retried; it pauses the source. `SourceBreaker` (Net.swift): 4 failures in a row pause a source 1→2→4→10 min, no network while paused, 404/offline/cancel don't count. Browse stops auto-loading when a page brings nothing new. Existing: max 6 image requests at once, in-flight dedupe, disk cache, search 4 sources at a time, library update one series at a time. |
| App lock: PIN + Touch ID (owner request) | Done (harness-tested; Touch ID not tried on hardware) | `LockScreen.swift` + `FolioCore/AppLock.swift`. PIN 4–8 digits stored only as PBKDF2-SHA256 (200k rounds, salted) in settings, never Keychain, never in backups (restore keeps this Mac's lock). Opens locked; re-locks after the chosen background time (at once…1 h), on screen sleep/lock and ⌘L. While locked a key monitor eats every key but ⌘Q, menus are disabled, other windows hidden, autoscroll stops. 5 wrong tries → wait 30 s, doubling to 15 min. Forgot PIN → Mac password (LocalAuthentication) removes it. Settings › Privacy. |
| Incognito keeps endless chapter scrolling (owner request) | Done (core-tested) | Unsaved series read in incognito are kept in memory only (`Library.passing`), so next/previous chapter, the chapter list and seamless chapters work; nothing is written. Saving one moves it into the library. |
| Extensions notice (owner request) | Done | one-time accept before anything extension-related starts or downloads; shown in Settings › Sources & extensions, About, README |
