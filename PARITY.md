# Folio vs Tachimanga — feature parity

Source: screens, settings and event names read from the Tachimanga app bundle on this Mac.
Scope: a *simple* alternative — core reading/library/extension features; no accounts, ads, subscriptions or cloud.

## Done
- Extensions from Tachiyomi/Mihon repos (Keiyoushi etc.), install/update/remove, language + 18+ filter
- Browse per source (Newest/Popular, search), endless scroll, covers
- Library, series page, chapters, read state, resume, bookmarks, per-chapter downloads
- Reader: webtoon (default), paged L→R / R→L, zoom, auto-scroll, chapter list, seamless chapters
- Local files (.cbz/.zip/folders) and OPDS servers (Komga/Kavita/Calibre)

## Batch 1 — building now
- [ ] Global search across all sources
- [ ] Library categories (create/rename/delete, assign, tabs)
- [ ] Library display modes (grid / compact / list), grid size, badges (unread, downloaded)
- [ ] Library filter (unread, downloaded, started, bookmarked, completed) + sort + random pick
- [ ] Chapter list filter; download next 1/5/10/unread/all; parallel queue; delete-after-read
- [ ] Incognito mode; clear history
- [ ] Auto-update library on launch
- [ ] Settings: library, downloads, updates, privacy, appearance, storage (cache/downloads size + clear)

## Batch 2 — in progress (researched against Tachimanga 5.x, Mihon, Aidoku, Suwayomi)
- [x] Reader: tap zones (thirds / edges / L-shaped / off) + invert, automatic background, skip-read chapters
- [x] Reader: right-click / press-and-hold page menu (copy / save / share / use as cover), crop borders (paged mode)
- [x] Reader: double-page spreads (cover alone, wide pages alone, RTL aware) + split wide pages into halves
- [ ] Reader: zoom limits, crop borders in webtoon, skip filtered/duplicate chapters
- [x] Source filters (genre/status etc. — the extension "FilterList"): checkbox, tri-state, text, select, sort, groups
- [x] Source preferences (per-extension settings, e.g. MangaDex content rating, data saver): toggle, text, list, multi-select
- [x] Backup / restore (Folio) + import Tachiyomi/Mihon (.tachibk) and Tachimanga (.tmb) backups, via the engine
- [ ] Series notes, edit cover, share
- [x] Migrate a series to another source (search every source, progress carries over, keep-original option); bulk migration not done
- [x] Update schedule (every 6h / 12h / day / 2 days / week, or on open) + skip rules (completed, unread, not started, categories)
- [x] Automatic daily backup (keeps the last N); choosable contents not done
- [ ] Security: option to disable sharing of links/images

## Later / maybe
- [ ] Tracking (AniList, MyAnimeList, Kitsu, Shikimori, MangaUpdates, Bangumi, MangaBaka, Comick)
- [ ] WebView for Cloudflare-protected sources
- [ ] App lock (Touch ID), read-time stats
