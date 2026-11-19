# Folio-Core — requirements

What Folio needs from its own core: the part of the app that finds, fetches and serves comics from sources.
This document states **what** Folio-Core must do and how well. **How** it is built (language, runtime, transport,
storage, libraries) is the Folio-Core team's decision and is deliberately not specified here.

Status: proposal, 2026-11-18.

---

## 1. Purpose

Folio-Core is the content engine behind Folio. Given sources the user has chosen to add, it can list what a source
offers, search it, describe a series, list its chapters, and deliver every page image, quickly and reliably, on every
platform Folio runs on.

The Folio app owns everything about the reader: library, reading progress, history, categories, downloads, update
scheduling, UI and settings. Folio-Core owns everything about sources.

### Core principles
1. **Folio-Core is stateless about the reader.** It never keeps a library, progress or history.
2. **Nothing happens unless asked.** No background jobs, timers or network traffic of its own.
3. **Local and private.** It serves only Folio on the same device, sends no telemetry, and contacts only the sites a
   request needs.
4. **One behaviour everywhere.** The same results and the same contract on Mac, iPad and iPhone.

---

## 2. Users and use cases

| # | As a reader I want to… | Folio-Core must… |
|---|---|---|
| U1 | add a source collection by pasting a link | accept the link, validate it, list what it offers |
| U2 | install, update and remove individual sources | do so safely, verify what it installs, report what changed |
| U3 | browse a source (popular, newest) endlessly | return pages of results, with "more available" |
| U4 | search one source, with that source's filters | expose the source's own filters and apply them |
| U5 | search all my sources at once | answer per source as each finishes; slow sources don't block |
| U6 | see a series' full details | give title, authors, artist, description, tags, status, cover, web link |
| U7 | see every chapter | give each chapter's name, number, date, group and web link, in order |
| U8 | read | give every page image of a chapter, fast, in order |
| U9 | adjust a source's own options (language, quality…) | expose and save each source's settings |
| U10 | get past "are you human" checks and logins | accept cookies and identity Folio provides, and say clearly when a check is needed |
| U11 | bring my library from Tachiyomi, Mihon or Tachimanga | read their backups and hand the library to Folio as data |
| U12 | know when a source is broken | report each source's health |
| U13 | check my whole library for new chapters quickly | check many series in one request, respecting each source's limits |

---

## 3. Functional requirements

### 3.1 Source collections ("repos")
- R1. Accept collection links in every format in current use: the protobuf index (`…/index.pb`, e.g.
  `https://github.com/keiyoushi/extensions/raw/repo/index.pb`), the JSON index (`…/index.min.json`), `repo.json`, and the
  collection's folder link.
- R2. Validate on add (reachable, real index, not empty) and give a specific reason when it fails.
- R3. List, add and remove collections; remember them.
- R4. Use the collection's signing information to verify what it installs. Warn when a source's signer changes.

### 3.2 Sources
- R5. **Run the existing Tachiyomi/Mihon extension ecosystem**, at minimum every extension in the Keiyoushi
  collection that doesn't require a live browser. Sources Folio-Core can't run must be listed with the reason, never
  silently missing or crashing.
- R6. List available sources: name, language, version, adult flag, obsolete flag, icon, update available, installed.
- R7. Install, update and remove a source. Updates are atomic: a failed update leaves the previous version working.
- R8. For each installed source report: id, name, language, has "newest" listing, adult flag, has settings,
  **home page link**.

### 3.3 Browsing and search
- R9. Popular and newest listings, page by page, with "has more".
- R10. Search with a query and the source's filters. Filter kinds: header, separator, checkbox, three-state,
  text, single choice, sort (with direction), group. Folio sends back the same structure with values changed.
- R11. Search across many sources in one request, delivering each source's results as soon as they arrive, with a
  per-source time limit and per-source errors.
- R12. Each result: the source's stable key, title, cover, plus any of authors, description, tags and status the
  source already provides.

### 3.4 Series and chapters
- R13. Full details: title, author, artist, description (with paragraphs), tags, status (unknown, ongoing, completed,
  licensed, publishing finished, cancelled, on hiatus), cover, web link.
- R14. Chapter list in the source's order: stable key, name, number, upload date, scanlation group, web link.
- R15. Check many series for new chapters in one request (R13 data for each), respecting rate limits and returning
  per-series results and errors.
- R16. **Stable identities**: series and chapters are identified by keys that survive restarts, reinstalls and moving
  to another device, so Folio's library, progress and downloads stay attached.

### 3.5 Pages and images
- R17. A chapter's page list, in order.
- R18. Each page's image, delivered exactly as the source requires (its headers, referrers, decoding of scrambled
  images and so on). Folio never needs to know how a source works.
- R19. Covers and source icons, optionally scaled down to a requested size.
- R20. Page references remain usable for at least 24 hours, including after Folio-Core restarts.
- R21. Requests can be cancelled; a cancelled request stops its network work.

### 3.6 Source settings
- R22. List a source's settings: on/off, switch, text, single choice, multiple choice, each with title, summary,
  current value, default, visibility and enabled state.
- R23. Change a setting and get the refreshed list back (summaries can depend on values). Settings persist.

### 3.7 Identity, cookies and human checks
- R24. Accept cookies from Folio (e.g. passed in Folio's web view) and use them for that site; list and clear them.
- R25. Use one browser identity (user agent) that Folio sets, so checks passed in Folio's web view stay valid.
- R26. When a site needs a human check or a login, say so explicitly with the site, so Folio can open it for the user.
- R27. Optionally use an external solver service the user configures.

### 3.8 Backups from other apps
- R28. Read Tachiyomi/Mihon backups (and Tachimanga backups after Folio converts them) and return the library as data:
  series with source, key, details and categories; chapters with read, bookmark and last-page state; history. Folio-Core
  stores none of it.

### 3.9 Health and status
- R29. Report readiness and version.
- R30. Per source: last success, typical and slow response times, error rate, last error.
- R31. Report what it has stored (sources, settings, cookies, caches) and its size, and clear any of it on request.

---

## 3.10 Output formats (the data contract)

General rules
- F1. Structured responses are **JSON**, UTF-8. Field names are camelCase. Unknown fields must be ignored by Folio,
  so Folio-Core may add fields within a version.
- F2. **Ids and keys are strings** (never numbers), opaque to Folio, stable per R16.
- F3. **Dates** are milliseconds since 1970-01-01 UTC (integer). Missing = field absent, never `0`.
- F4. **Optional fields are omitted when unknown**, never sent as empty strings.
- F5. **Text** is plain text; descriptions keep paragraph breaks as `\n`. No HTML.
- F6. **Images** are raw bytes with the correct media type (`image/jpeg`, `image/png`, `image/webp`, `image/gif`,
  `image/avif`); never re-encoded unless the source scrambles images or a size was requested (R19).
- F7. **Lists that arrive over time** (R11 multi-source search, R15 batch update) are delivered as a stream of
  self-contained records, one per source or series, each with its own `status` (`ok` or an error, §4), then a final
  `{ "done": true }` record.
- F8. **Paged lists** are `{ "items": [...], "hasNextPage": true|false }`. Pages start at 1.
- F9. Every response that concerns a source includes its `sourceId`.

Records

```
Repo        { url, name, website?, signingFingerprint?, sourceCount }
Extension   { id, name, lang, version, isInstalled, hasUpdate, isObsolete, isNsfw, iconRef?, repoUrl,
              unsupportedReason? }
Source      { id, name, lang, displayName, extensionId, supportsLatest, isNsfw, hasSettings, homePage? }
SeriesCard  { sourceId, key, title, coverRef?, author?, artist?, description?, tags?, status? }
Series      { sourceId, key, title, coverRef?, author?, artist?, description?, tags[], status, webUrl? }
            status ∈ unknown | ongoing | completed | licensed | publishingFinished | cancelled | onHiatus
Chapter     { key, name, number?, uploaded?, group?, webUrl? }      (number: decimal, e.g. 12.5)
Page        { index, imageRef }                                     (index from 0, in reading order)
Filter      { kind, name, ... } kind ∈ header | separator | checkbox{state} | triState{state: ignore|include|exclude}
            | text{value} | select{options[], selected} | sort{options[], selected?, ascending} | group{filters[]}
Setting     { key, kind, title, summary?, visible, enabled, value, default, options?[{label, value}] }
            kind ∈ toggle | switch | text | choice | multiChoice
Cookie      { domain, path, name, value, expires?, secure, httpOnly }
Health      { sourceId, lastSuccess?, p50Ms?, p95Ms?, errorRate, lastError? }
Status      { version, contractVersion, ready, uptimeMs, sourcesLoaded }
Storage     { sourcesBytes, settingsBytes, cookiesBytes, cacheBytes }
BackupItem  { sourceId, key, series: Series, categories[], chapters[{ key, read, bookmarked, lastPage?, readAt? }] }
Error       { code, message, sourceId?, site?, retryAfterMs? }      (see §4)
```

`coverRef`, `iconRef` and `imageRef` are opaque references Folio passes back to fetch the bytes (R18–R20).

---

## 4. Errors

- R32. Every failure carries a code from a fixed set Folio can act on: offline, timed out, human check needed,
  login needed, rate limited (with when to retry), not found, source broken, source unsupported, bad request,
  internal. Plus a short human message and the source involved.
- R33. Internal details (stack traces, raw responses) never reach Folio's UI; they go to Folio-Core's own log.

---

## 5. Quality requirements

| Area | Requirement |
|---|---|
| Install size | small enough to ship inside Folio; target ≤ 40 MB including anything it needs to run |
| First use | works on first launch with no separate installs, downloads or setup by the user |
| Start | ready in ≤ 1 s warm, ≤ 3 s cold on a current Mac; measured and published for iPhone/iPad |
| Speed | adds ≤ 50 ms over the source's own response time per call |
| Memory | ≤ 250 MB with 10 sources in use |
| Concurrency | ≥ 16 requests at once; each source's rate limits respected |
| Isolation | one broken or hostile source can't crash, hang, or slow down others or Folio-Core |
| Background activity | none |
| Battery | idle = zero CPU and zero network |
| Privacy | no telemetry; no traffic except what requests cause; all data in a folder Folio chooses |
| Security | reachable only by Folio on the same device; secrets never visible to other processes or users; sources can't read Folio-Core's or Folio's private data |
| Logging | rotated, size-capped, cookies and secrets redacted |
| Contract | versioned; changes within a version are additive only |

---

## 6. Platform constraints

- P1. Must run on macOS 15+ and later inside Folio on iPadOS and iOS, **within App Store rules** (for example, no
  runtime code generation where the platform forbids it).
- P2. On iOS it runs inside the app; it must tolerate being suspended and resumed, and memory warnings.
- P3. No dependency the user must install themselves.
- P4. Data location is given by Folio; nothing written elsewhere.

---

## 7. Legal

- L1. No content, sources or collections are bundled; users add them (see Folio's notice in `README.md`).
- L2. Every third-party component's licence is honoured and listed in `NOTICE.md`.
- L3. No code is copied from projects whose licence would bind Folio-Core in ways the owner hasn't agreed to.

---

## 8. Acceptance

- A1. A test corpus of the 50 most-used Keiyoushi sources plus every source the owner uses. For each source:
  list → popular page 1 → details → chapters → pages → first image displays. ≥ 95 % pass; failures have a clear code.
- A2. Results match what the same sources give in today's engine (titles, keys, chapter counts).
- A3. Quality targets in §5 measured on a reference Mac and a reference iPhone, published with each release.
- A4. Folio's own self-test gains a Folio-Core suite that runs offline from recorded responses.

---

## 9. What Folio will do on its side

- Talk to Folio-Core through one interface, so it can switch engines behind a setting.
- Convert existing libraries to Folio-Core's stable keys (R16), with a backup first, and keep progress and downloads.
- Show Folio-Core's error codes (§4) as plain messages, and open Folio's web view on "human check needed".

---

## 10. Features Folio-Core makes possible

**Speed**
- Library update in one batch request (R15) → an Updates inbox that fills in seconds.
- Streaming search across all sources (R11) → global search that never waits on the slowest source.
- Scaled-down covers (R19) → a lighter, faster library grid.
- Next-chapter warm-up: Folio asks for the next chapter's first pages while you read.

**Reliability**
- Source health (R30) → a warning dot on broken sources and one-click migration to a working one.
- Human checks that "just work": pass once in Folio's web view, then every request works (R24–R26).

**Discovery**
- A "Website" button for every source (R8).
- Cross-source matching: find the same series on other sources with chapter counts → migration suggestions,
  duplicate detection, and a blacklist that hides a series on every source.
- Release-day learning from chapter dates (R14/R15) → check only on a series' release days; a release calendar.

**Trust**
- Show which websites each source contacts; warn when a source's signer changes (R4).

**Optional, off by default**
- Fill missing descriptions and tags from AniList or MangaUpdates (contacts a third party, so the user opts in).

**Product**
- A single Folio download that does everything on first launch, with nothing extra to install (§5, P3).
- The same core inside Folio for iPad and iPhone (§6).
