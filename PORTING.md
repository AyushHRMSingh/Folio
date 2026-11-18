# Folio — iPad / iPhone port (parked)

Parked on 2026-11-18: the focus now is the Mac app (`WORKERS.md`). Nothing here is scheduled yet.

---

## Architecture decisions

These shape today's code, so they're worth deciding before the codebase grows:

1. **Run the same extension engine on every device — in-process on iOS, like Tachimanga.**
   *How Tachimanga does it (verified from `/Applications/Tachimanga.app`):* Flutter UI + an **Eclipse OpenJ9 JVM
   (JDK 17) ported to iOS and statically linked into the app binary**, running **interpreter-only** (iOS forbids JIT).
   It bundles a trimmed JRE (`jre/lib/modules`, 93 MB) and **Suwayomi/Tachidesk-Server v0.7.0** as a jar
   (`MCHome.bundle/res.zip`: `suwayomi.tachidesk.MainKt`, Jetty/Javalin, Exposed/SQLite, **dex2jar** to turn extension
   APKs into jars on-device). The UI talks to that server on localhost — the exact architecture Folio already has on Mac.

   *Folio plan — one engine, two launchers:*
   - **Mac** (today): HotSpot JVM as a child process (keeps the JIT; fast). No change.
   - **iPad/iPhone**: embed an interpreter-only OpenJ9 XCFramework (e.g. the open-source
     [openj9-ios](https://github.com/stardewjames/openj9-ios) port, Java 21) and start the **same pinned Suwayomi jar**
     in-process on 127.0.0.1. `ExtensionEngine` keeps its GraphQL API; only `start()` differs per platform.
   - **Optional remote mode** on all platforms: point at a Suwayomi server (your Mac, NAS). Fallback, not the plan.

   *Risks to retire first (spike before anything else):*
   - **Speed:** interpreted JVM — measure cold start, first `popular` call, and dex2jar time for a big extension on a
     real iPhone. Tachimanga ships it, so it's viable; we need our numbers.
   - **Memory / background:** iOS kills big apps in background and suspends the server. Do page/chapter *downloads*
     in Swift (`URLSession` background sessions) using URLs + headers the engine returns, not inside the JVM. Restart
     the engine lazily on foreground.
   - **Server version:** Tachimanga pins an old server (v0.7.0). Folio's Mac pin and the iOS jar must be the same version
     and must run on the iOS JVM's Java level (openj9-ios is Java 21 — check the jar's target).
   - **App Store:** running downloaded extension code in an interpreter is the grey area (guideline 2.5.2). Tachimanga
     and others are approved; keep extensions user-added (no bundled repo), and plan TestFlight/AltStore as fallback.
   - **Licensing:** OpenJ9 (EPL-2.0/Apache-2.0) + OpenJDK class libraries (GPLv2 + Classpath Exception) — fine to embed,
     but ship notices and offer the JVM sources for the binaries you distribute.
   - **Size:** ~100–150 MB extra download. Acceptable (Tachimanga is the same).

   *Keep the `Source` protocol the only thing the UI knows*, so local engine, embedded engine and remote server are
   interchangeable.
2. **Keep `FolioCore` free of AppKit.** Images use `NSImage` in the app layer — move decode/downsample to
   `CGImage`/ImageIO in core so iOS reuses it.
3. **Reader canvas is AppKit (`NSScrollView` + CALayer tiles).** Plan a `UIScrollView` twin behind the same
   `ReaderModel`; keep all reading logic (slots, aspect ratios, offset compensation, progress) in the model, not the view.
4. **Storage → per-record** (see Sync) instead of one `library.json`, so sync and large libraries scale.
5. **Layouts**: design the new sidebar nav (already a left sidebar on Mac) as `NavigationSplitView` — it collapses to a tab bar /
   stack on iPhone for free.
6. **Touch-first reader controls** on iOS: tap center toggles bars, edge taps page, long-press menu (which *is* right on
   iOS — long-press was removed on Mac; bring it back behind a platform check on iOS).

---


## Sync (prerequisite)

- ★ **iCloud sync of library state**: saved series, categories, read progress, bookmarks, settings. Use CloudKit
  (private DB) or an iCloud Drive JSON with per-record timestamps + last-writer-wins per chapter. Design the merge now
  even if it ships later — `library.json` as one blob won't merge. L
- **Self-hosted alternative**: sync via a Suwayomi server the user already runs (it has a tracking/sync API). M

---


## Order when this resumes

1. **iOS engine spike (do early, in parallel — it's the biggest unknown):** a throwaway iOS target that boots
   openj9-ios + Folio's pinned Suwayomi jar on a real iPhone, installs one extension, loads Popular. Record timings
   and memory. Go/no-go for the shared-engine plan.
2. Core refactors for portability (ImageIO in core, per-record storage, `ExtensionEngine` launcher split) → sync →
   iPad app → iPhone.
