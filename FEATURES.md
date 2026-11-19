# Folio — feature brainstorm (2026-11-18)

Goal: the most convenient reader there is. Mac first, iPad/iPhone later. `PARITY.md` tracks the Tachimanga
checklist; this file is everything *beyond* parity — what would make Folio better than the others, not just equal.
Nothing here is scheduled until `WORKERS.md` steps 1–4 are done.

Each item: **what** · *why it matters* · effort (S/M/L). ★ = do these first.

---

## 1. Reading (the core — webtoon first)

- ★ **Continuous "just keep reading" across chapters** with an end-of-chapter strip (chapter title, uploaded date,
  "3 more unread") instead of a full card that interrupts the scroll. *Webtoon readers binge.* S
- ★ **Smart resume to the exact pixel**, not just page: store the offset inside a tall page. Webtoon pages can be 10,000pt;
  page-level resume drops you far off. S
- ★ **Auto-scroll that feels human**: speed in "screens per minute", ±-keys while running, pauses on hover/trackpad touch,
  resumes after 1s idle. Show speed briefly on change. M
- ★ **Keyboard-first reading**: Space/⇧Space = 90% screen, J/K = small step, ←/→ chapters in webtoon, G/⇧G top/bottom,
  `?` shows a shortcut overlay. Make every key rebindable later. S
- **Trackpad gestures**: two-finger swipe left/right = prev/next chapter (with rubber-band hint), pinch already zooms. S
- **Per-series reader memory**: mode, width, background, crop remembered per series (PARITY has mode only). S
- **Width presets** in the reader bar: Narrow / Comfortable / Full, plus "fit height" for paged. Faster than a slider. S
- **Reading ruler / dim-around-focus** (optional): darkens everything but a band — useful for dense text-heavy manhwa. S
- **Image enhancements**: sharpen/upscale for low-res scans (Core Image Lanczos + optional on-device super-resolution
  via Core ML), auto brightness/contrast, grayscale for B/W manga to cut JPEG artifacts. M
- **Page gap detection**: auto-join split webtoon strips (some sources cut panels mid-image) so there's no seam. M
- **Panel-by-panel mode** for paged manga on small screens (big win on iPhone later). L
- **Chapter comments / translator notes** from sources that expose them (some extensions do). M

## 2. Library & discovery

- ★ **"Up next" shelf** at the top of the library: series with unread chapters, ordered by most recently updated —
  one click resumes. This is the screen most users actually want. S
- ★ **New chapters inbox ("Updates")**: chronological list of newly found chapters across the library, mark-read/
  download inline, grouped by day. Tachiyomi's most-used tab; Folio doesn't have it yet. M
- ★ **Bulk select** everywhere (library, chapters, updates): ⌘-click / ⇧-click / drag-select, then mark read, download,
  move category, remove. S–M
- **Smart categories** (saved filters): "Completed & unread", "Not touched in 30 days", "Webtoons", "Has downloads". M
- **Series status at a glance**: "caught up", "N behind", "on hiatus" (no update in 60 days), "ended". S
- **Duplicate detection**: same title saved from two sources → offer merge (keeps the higher chapter count, best cover). M
- **Recommendations / "similar"** from tracker data (AniList/MAL) once tracking exists. M
- **Tags & genres you can browse** across your own library (click a genre on a series page → library filtered). S
- **Custom covers & titles** (rename a badly-named source title, pick any page as cover — the latter already exists). S
- **Notes per series** (PARITY lists it). S

## 3. Sources & extensions

- ★ **Source health**: per-source last success, average latency, error rate; show a warning badge on broken sources
  and suggest migration. *Sources break constantly; users don't know why nothing updates.* M
- ★ **One-click popular repo** in the empty Extensions state (with a clear "third-party" note), plus deep-link
  `folio://add-repo?url=…`. S
- **Pinned sources** and a per-source "Latest" feed merged into one "Latest from my sources" view. M
- **Auto-migrate suggestions**: when a series' source is dead or behind another source by N chapters. M
- **Cloudflare flow built in**: when a source hits a challenge, open the WebView sheet automatically, then retry
  (instead of relying on FlareSolverr). M

## 4. Downloads & offline

- ★ **Auto-download new chapters** for chosen categories (with "only on Wi-Fi/power" for later mobile). S
- ★ **Download queue screen**: reorder, pause/resume, retry failed, per-series grouping, ETA. (Today it's a cancel-only
  "↓ 3".) M
- **Keep next N unread downloaded** per series (rolling window) — the convenient middle ground. S
- **Export to CBZ** (single chapter or whole series) for archiving/other readers. S
- **Storage budget**: cap downloads at X GB, evict oldest-read first. S

## 5. Tracking & stats

- **Trackers**: AniList + MyAnimeList first (most users), MangaUpdates next. Auto-update progress on chapter finish. L
- **Reading stats**: time read, chapters per week, streak, top series — local only, private. M
- **Year in review** page (fun, shareable image). S

## 6. Mac-native convenience

- ★ **Menu bar & Dock badge**: unread new-chapter count on the Dock icon; optional menu-bar item listing "Up next". S
- ★ **Proper menus & shortcuts**: ⌘1–4 sections, ⌘[ back, ⌘, settings, ⌘F search, ⌘R update, ⌘L focus search S
- **Multiple windows / tabs**: read in one window, browse in another (⌘N / ⌘T). M
- **Notifications** for new chapters (grouped, with "Read" action that opens straight into the reader). S
- **Spotlight & Shortcuts (App Intents)**: "Continue reading", "Open series X", "Check for updates". Same intents work
  on iOS later. M
- **Drag & drop**: drop .cbz/folders on the window or Dock icon to import; drag a page out to save it. S
- **Quick Look** previews for .cbz in Finder (thumbnail + pages) via a QL extension. M
- **Picture-in-picture-style mini reader**: a small always-on-top window that auto-scrolls. Niche but delightful. M
- **Handoff** between Mac and iPad/iPhone (once ported): "Continue reading on iPad". S (after sync)

## 7. Privacy & safety

- App lock (Touch ID), per-category hide (e.g. 18+ categories hidden unless unlocked), incognito per-source. S–M
- Blur covers in the library for flagged sources (screen-share safe). S

## 8. Round 2 (2026-11-18) — more ideas

### UX principles (apply to every feature, new or old)
- **Undo beats confirm.** Reversible actions (mark all read, remove from library, clear history, delete category)
  happen at once with an "Undo" toast for ~6 s. Keep confirmation dialogs only for truly irreversible things
  (deleting downloaded files, restoring a backup).
- **Hover reveals, click commits.** Secondary actions appear on hover in place (cover, chapter row, recent row);
  nothing important lives only in a right-click menu, and nothing needs a long-press.
- **Everything is keyboard-reachable.** Every grid and list has a selection you move with arrows; Return opens,
  Space previews, ⌘⌫ removes. Every action has a menu-bar item (so it's searchable in Help › Search).
- **Never block on the network.** Show cached data instantly, refresh behind it, mark stale data quietly.
- **One summon model in the reader** (D4): edges, click, `M`. Nothing else appears unasked except errors.

### Reading
- ★ **"Back to where you were" (⌘Z in the reader).** After a scrub, a chapter jump or an accidental End key, one key
  returns to the exact previous position. A small history stack, like Xcode's navigation. *Accidental scrubs on a
  long webtoon are the most common way to lose your place.* S
- ★ **Scrubber previews.** Hovering the page scrubber shows a thumbnail of that page and its number. S
- ★ **Open where I left off.** Optional: if you quit while reading, Folio relaunches straight into the reader at that
  spot. S
- **Trackpad haptic tick at chapter boundaries** (`NSHapticFeedbackManager`), so you feel the chapter change in
  continuous scrolling without any on-screen label. S
- **Per-display width memory.** Remember reader width separately for the laptop screen and an external monitor
  (keyed by display), because the right width differs. S
- **Warm/dim reading filter** independent of system Night Shift: brightness and warmth sliders in the reader panel. S
- **Translate a page (raws).** Vision OCR finds speech bubbles; Apple's on-device Translation framework (macOS 15)
  overlays a translation on demand. Also: select text in a bubble to copy or look it up. *Unique — lets people read
  chapters before scanlations exist.* L
- **Density-aware auto-scroll.** Use Vision text detection to slow down on text-heavy panels and speed through
  wordless ones. M
- **Panel zoom on double-click (paged mode):** detect the panel under the cursor and zoom to fit it; double-click
  again to return. M
- **Save a panel ("Moments").** Drag a rectangle on a page to save that panel into a per-series gallery; export or
  share. M

### Library
- ★ **Command palette (⌘K).** Type to jump to any series, chapter ("solo 145"), screen, setting or action
  ("update library", "toggle incognito"). Fits the keyboard-first goal and removes the need to hunt through menus. M
- ★ **Quick Look a series (Space on a selected cover).** A preview panel with cover, summary, unread count and a
  Continue button — no navigation needed. The Mac's own idiom. S–M
- ★ **Continue from the cover.** Hovering a cover shows "▶ Ch. 12"; one click resumes reading without opening the
  series page. S
- **Reading status per series** — Reading / Plan to read / On hold / Dropped / Completed — separate from categories,
  with a filter. Matches how trackers think, so it maps onto AniList/MAL later. S
- **"Read next" queue.** A small ordered list you build by hand (drag to reorder) for what to start next, distinct from
  categories. S
- **Focus mode.** One toggle hides caught-up, completed and dropped series so the grid shows only what has something
  to read. S
- **Smart cover crop.** Use Vision's saliency detection to crop non-2:3 covers around the subject instead of the
  centre. S
- **Shelves layout.** Optional view with one horizontal row per category (and "Up next" first) instead of one grid. M

### Updates & discovery
- ★ **Learn each series' release day.** From chapter upload dates, infer the schedule ("weekly, Wednesdays") and check
  then; show "next expected Wed" on the series page and a **release calendar** view. *Fewer pointless checks, less
  load on sources, and users know when to come back.* M
- **Merged global search results.** Group the same title across sources into one result, show which source has the
  most chapters / is fastest, mark what's already in the library. M
- **"Add to Folio" from Safari.** A share/Services entry: send a manga page URL from the browser; Folio finds it via
  the installed extensions and offers to save it. M
- **Watch without saving.** Follow a series for new-chapter alerts without putting it in the library. S

### Offline & updates convenience
- ★ **"Get ready for offline" button.** Downloads the next N unread chapters of everything in Up next, with a total
  size estimate first. *For flights and commutes.* S
- **Download size estimate** before any bulk download. S

### Mac integration
- **Desktop widgets (WidgetKit):** Up next covers with progress; tap to continue. The same widget carries to iOS. M
- **Focus filter:** hide 18+ categories/sources while a chosen Focus (e.g. Work) is on. S–M
- **Keyboard navigation in grids** (arrows/Return/Space, see principles). S

### App icon (owner request)
- **Bookshelf icon** — old leather-bound spines (oxblood, forest green, navy, cognac, ochre, gold bands) on a walnut
  shelf, near-black tile. **Adopted** — source `Resources/AppIcon.svg`, built with `Tools/make-icon.sh` into `Resources/AppIcon.icns`, installed by `install.sh`.
- **Icon customisation** — Settings › Appearance › App icon: Classic (multicolour), Black & white, or a single tint
  colour. Running Dock icon via `NSApp.applicationIconImage`; Finder/Launchpad icon via
  `NSWorkspace.setIcon(_:forFile:)` on the app bundle (check this doesn't break the code signature; with Developer ID
  signing, keep the bundle untouched and only swap the Dock icon). Variants rendered from the same vector with a palette
  swap. M

### First run & onboarding
- ★ **First-run setup in three steps:** add a local folder · add an extension repo · (checks Java, offers the
  installer — ties to E2). Skippable; shown again from Settings › Sources. S
- **One-time reader hint** the first time you open a chapter: "Move to the top or bottom edge for controls ·
  Space to scroll · S for reading settings". Dismissed forever after one read. S

## Later: iPad / iPhone

Parked in `PORTING.md` (shared extension engine via embedded JVM, sync, core refactors).

## Suggested order

1. `WORKERS.md` steps 1–4 (finish fixes, owner decisions, consistency pass, structural cleanup).
2. ★ items in Reading + Library: exact resume, up-next shelf, Updates inbox, bulk select, keyboard shortcuts,
   "back to where you were", continue-from-cover, command palette, Quick Look, undo toasts (principle).
3. Downloads queue screen + auto-download.
4. Mac-native: menus, Dock badge, notifications, drag-drop import.
5. Source health + Cloudflare flow.
6. Trackers, stats, polish features.
