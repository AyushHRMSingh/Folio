# Third-party notices

Folio is an independent project. It is not affiliated with, endorsed by, or sponsored by Tachimanga, Tachiyomi, Mihon,
Suwayomi, Komga, Kavita, Calibre-Web, or Eclipse Adoptium. All trademarks belong to their respective owners.

## Suwayomi-Server (downloaded, not bundled)

- Project: https://github.com/Suwayomi/Suwayomi-Server
- License: Mozilla Public License 2.0 (MPL-2.0)
- Folio does not ship this software. When you first use extensions, Folio downloads the pinned release
  (`v2.4.2366`) from the project's official GitHub releases, verifies its SHA-256 checksum, and runs it locally as a
  child process on 127.0.0.1. The version and checksum are defined in `Sources/FolioCore/Engine.swift`.
- Folio does not modify the Suwayomi-Server jar. Its source code and license text are available at the link above.

## Java (installed by you, not bundled)

Running the extension engine requires Java 21 or newer, which you install yourself, for example Eclipse Temurin
(GPLv2 with Classpath Exception): https://adoptium.net/temurin/releases/?os=mac&package=jdk&version=21

## Extensions

Extensions and extension repositories are made by third parties and are added by you. Folio ships none and does not
vouch for them. Folio is compatible with the Tachiyomi/Mihon extension format through the Suwayomi engine; this
describes technical compatibility only and implies no affiliation.
