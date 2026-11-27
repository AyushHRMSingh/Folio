# Folio — working notes

A simple Tachimanga alternative for macOS. Goal: simple, fast, stable. Webtoon reading is the primary mode.
Feature checklist: `PARITY.md` (derived from Tachimanga's own screens/settings). Batch 1 is built; batch 2 is next.
**Worker sessions: read `WORKERS.md` first** — process, the owner's binding UX decisions, next steps and status.
Ideas: `FEATURES.md`. Parked iPad/iPhone plan: `PORTING.md`. Proposed Suwayomi replacement: `FOLIO-CORE.md`.

## Layout
- `Sources/FolioCore` — no UI. `Models`, `Source` protocol (Tachiyomi-style: popular/search/details/chapters/pages),
  `LocalSource`, `OPDS`, `Engine` (extension engine + `ExtensionSource`), `Library` (state, categories, queue), `Storage`.
- `Sources/FolioApp` — SwiftUI shell + native AppKit reader canvases (`ReaderCanvas.swift`).
- `Sources/foliotest` — end-to-end self-test of the core. Run it after every core change.
- `Tools/` — QA harness (`qa.sh`), test-data generator, debug sender.

## Decisions worth knowing
- **Reader** (`ReaderCanvas.swift`): `NSScrollView` + CALayer tiles. Zoom is the scroll view's *magnification* (magnifies the
  viewport; never relayouts pages). Pages sit in fixed slots; when an image's real height is known, everything below shifts
  and the viewport is compensated (proportionally when the image straddles the top edge) so loading never moves what you read.
  Placeholder height uses the chapter's typical aspect ratio. Tiles outside ±4 viewports are dropped.
  `ReaderModel` (in `Reader.swift`) owns chapter streaming (next chapter appended seamlessly), progress and controls.
- **Zoom and page width are independent**: width = Reader settings slider (`webtoonWidth`); zoom = pinch / + / − / 0 / double-click.
- **Extensions**: Folio launches the Suwayomi server jar (pinned version + SHA-256 in `Engine.swift`, stored in
  `~/Library/Application Support/FolioEngine`) as a child process on 127.0.0.1 with a random port and random Basic-auth login.
  Its data lives in Folio's data folder. Repos are added with the GraphQL mutation `addExtensionStore` (NOT `extensionRepos`
  in settings — that is ignored by this server version). A `/bin/sh` supervisor stops Java if Folio dies.
- **Persistence**: one JSON file, `~/Library/Application Support/Folio/library.json`. Models decode tolerantly — new fields
  must be optional or have a `decodeIfPresent` default so old files keep loading (there's a test for this).
- **Images**: decoded off the main thread and downsampled (`Images` in `AppModel.swift`); aspect ratios are remembered.
- **One request per image at a time** (`SharedFetch` in `Net.swift`): two concurrent requests for the same page make the
  engine write the same `manga-cache/…/NNN.tmp` twice and one response breaks off mid-image (smeared, then black pages).
  `ImageFetch` also rejects cut-off images (JPEG/PNG/GIF/WebP end markers), retries, and never caches them.
  Very tall pages are drawn as 4096 px slices (`PageTile.setImage`).
  Page lists are shared the same way (`Library.pageListLoads`). Promotion of a queued page goes through
  `ImageFetch.promote(alias:)` (the page URL), since scheduler keys are source-prefixed (`e|…`, `o|…`).
  Downloads refuse non-image or cut-off pages. Cover max age counts from when it was fetched, not last viewed.
- Min macOS 15; `Package.swift` uses tools 6.0 with Swift 5 language mode.
- The Folio window toolbar is hidden while reading; `AppModel.setReaderChrome` enforces it (SwiftUI keeps re-showing it).

## Debug / QA hook (dev only)
Launching with `FOLIO_DEBUG=<token>` makes Folio listen for distributed notifications `local.folio.debug.<token>`
(`DebugHook.swift`). No screen-recording permission is needed — snapshots capture Folio's own window.
`Tools/qa.sh start|send|snap|log|stop` wraps it (off-screen, throwaway HOME, never steals focus).
Commands: `size:WxH` `sidebar:library|recents|search|extensions|settings|downloads|<source id>` `fake-downloads` (made-up paused queue on the Downloads page) `series:<title>` `back` `read:<title>`
`open-local:<folder>` `add-local:<folder>` (a series folder inside the local library; name or path) `cat-new:<name>` `cat-set:<series>|<category>` `set:display=list|sort=title|incognito=on|hidesaved=on|notice=on|off|pin=<digits>|pin=off` `lock` `type-pin:<digits>`
`set:pin=touchid` `set:privacy=on|off` `set:mode=webtoon|rightToLeft|leftToRight` `privacy:on|off` (black background cover) `setup:show|done` `setup-step:<0-3>` (first-launch setup; `qa.sh start` marks it done) `gsearch:<query>` `cmd:viewport:<f>` `cmd:points:<n>` `cmd:zoomin|zoomout|zoomreset` `cmd:next|prev` `cmd:page:<n>`
`cmd:mode:webtoon|rightToLeft|leftToRight` `cmd:controls:on|off` `cmd:popover:chapters|settings|none` `web:<url>` `repo-add:<index url>` `blacklist:<title>` `cmd:autoscroll:on` `cmd:width:<0.3-1>|crop:on|double:on|split:on` (this comic only) `state` `snap:<png>` `quit`.
Input/UI commands: `fullscreen:on|off` (toggles only if state differs; logs result after 2s), `key:<spec>` (synthesized keyDown+keyUp via NSApp.sendEvent, e.g. `key:esc` `key:space` `key:s` `key:]` `key:cmd+[` `key:cmd+shift+k`; logs target window + first responder), `popover-dump` (logs class/frame/accessibility tree of visible non-main windows such as the reader settings popover; SwiftUI text is mostly not exposed, so prefer the snapshot), `snap-popover:<png>` (captures the first such window), `hover:<x>,<y>` (mouseMoved at window point from top-left).
Env: `FOLIO_DEBUG_NO_JAVA=1` pretends Java is missing (Extensions' install panel). `FOLIO_DEBUG_FAIL=1` makes every page whose file ends in 2.png/2.jpg fail as a paused source (checks page messages). `FOLIO_DEBUG_DELAY=1.5` simulates slow page loads (used to prove load-in stability: every page load left the view still).

## Status
- Batch 1 (global search, categories, display modes, filters/sort/random, download queue + delete-after-read, incognito,
  clear history, auto-update on launch, storage tools, appearance) is implemented and core-tested.
- Visually reviewed (via `Tools/qa.sh` snapshots): library grid with category bar, library list, global search, Settings.
  NOT yet reviewed: compact display mode, the category assign/edit sheets, the series-page Download menu and chapter
  filter, the incognito indicator while reading, and the download queue with a real extension source.
- User preferences: laptop-friendly side margins in the reader, no "Load More" buttons (auto-load at list end), no overlap or
  jumping while pages load, tasteful UI. Folio is the product — keep it simple.
