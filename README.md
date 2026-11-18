# Folio

A simple manga / webtoon reader for macOS — a Mac alternative to Tachimanga/Mihon.
Paste a Tachiyomi/Mihon extension repo (e.g. Keiyoushi), install extensions, read.

- **Extensions**: runs the real Android extensions through the open-source Suwayomi engine (needs Java 21+)
- **Sources**: extensions, local `.cbz`/`.zip`/folders, OPDS servers (Komga, Kavita, Calibre-Web)
- **Library**: categories, filters, sort, display modes, unread/download badges, continue reading
- **Reader**: webtoon (default), paged left→right / right→left, viewport zoom, auto-scroll, seamless chapters
- **Downloads**: queue, offline reading, delete after reading · **Incognito** · global search

## Build
```sh
swift build -c release          # requires macOS 15+, Swift 6 toolchain
./install.sh                    # builds ~/Applications/Folio.app
.build/release/foliotest        # core self-test (offline)
.build/release/foliotest --extensions   # also tests the real extension engine (network)
```

See `PARITY.md` for the feature checklist and `CLAUDE.md` for architecture notes.
