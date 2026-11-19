# Folio

A simple, fast manga and webtoon reader for macOS, and a Mac alternative to Tachimanga/Mihon. Read your own files,
OPDS servers, or sources from Tachiyomi/Mihon-compatible extensions that you choose to add. Webtoon reading is the
primary mode.

## Features

- **Sources**: extensions (via the open-source Suwayomi engine), local `.cbz`/`.zip`/folders, OPDS servers (Komga, Kavita, Calibre-Web)
- **Library**: categories, filters, sort, display modes, unread/download badges, continue reading, global search
- **Reader**: webtoon (default) plus paged left-to-right / right-to-left, viewport zoom, auto-scroll
- **Continuous scrolling** across chapters, both forward and backward, with no jumping while pages load
- **Per-comic reading settings** that override the global defaults, plus dedicated settings pages
- **Downloads**: queue, offline reading, delete after reading
- **Incognito** mode and appearance options

## Requirements

- macOS 15 or later
- Java 21+, only if you use extensions: [Eclipse Temurin](https://adoptium.net/temurin/releases/?os=mac&package=jdk&version=21)

## Install / build from source

```sh
swift build -c release          # requires macOS 15+, Swift 6 toolchain
./install.sh                    # builds ~/Applications/Folio.app
.build/release/foliotest        # core self-test (offline)
.build/release/foliotest --extensions   # also tests the real extension engine (network)
```

## Privacy

All data stays on your Mac, in `~/Library/Application Support/Folio` and `~/Library/Application Support/FolioEngine`.
There are no accounts, no analytics and no telemetry. Network access happens only for sources you add and for the
one-time engine download.

## Disclaimer

Folio is a reader. It comes with no content, no extension repos and no sources.
Extensions and repos are made by third parties; you choose what to add, and **you alone are responsible for the
content you import, read or download with Folio**, and for following the law where you live.
Folio does not condone reading copyrighted work without paying for it. When a series is officially available,
read it there and support the people who make it.

## License

No license has been chosen yet; all rights reserved by the author until one is added.

Third-party software and trademarks are covered in [NOTICE.md](NOTICE.md).

See `PARITY.md` for the feature checklist and `CLAUDE.md` for architecture notes.
