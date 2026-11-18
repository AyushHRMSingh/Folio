import AppKit
import FolioCore
import Foundation

// End-to-end checks of Folio's core: local files, chapter numbering, a real OPDS server with
// Basic auth and page streaming, library state, downloads and persistence. Runs in a throwaway HOME.

let tmp: URL = {   // resolved path, so /var vs /private/var aliasing can't confuse prefix checks
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("folio-test-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    let r = realpath(u.path, nil)!; defer { free(r) }
    return URL(fileURLWithPath: String(cString: r), isDirectory: true)
}()
setenv("HOME", tmp.path, 1)
var failures = 0
func check(_ ok: Bool, _ what: String) { print("\(ok ? "PASS" : "FAIL")  \(what)"); if !ok { failures += 1 } }

func png(_ label: String) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 60, pixelsHigh: 90, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 60, height: 90).fill()
    (label as NSString).draw(at: NSPoint(x: 4, y: 40), withAttributes: [.font: NSFont.systemFont(ofSize: 10)])
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
func write(_ d: Data, _ u: URL) { try! FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true); try! d.write(to: u) }
func run(_ exe: String, _ args: [String], cwd: URL? = nil) { let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args; p.currentDirectoryURL = cwd; p.standardOutput = FileHandle.nullDevice; try! p.run(); p.waitUntilExit() }

@MainActor func main() async throws {
    // ---------- chapter recognition
    let cases: [(String, Double)] = [("Chapter 12", 12), ("Vol.2 Ch. 12.5 - Title", 12.5), ("chapter_007.cbz", 7),
                                     ("Episode 3", 3), ("Series Name 045", 45), ("Vol 3 Extra", -1), ("Oneshot", -1)]
    check(cases.allSatisfy { ChapterRecognition.number(from: $0.0) == $0.1 },
          "chapter numbers parsed (" + cases.map { "\($0.0)→\(ChapterRecognition.number(from: $0.0))" }.joined(separator: ", ") + ")")

    // ---------- local source
    let local = Paths.localLibrary
    check(local.path.hasPrefix(tmp.path), "all data lives under $HOME (\(Paths.root.path.replacingOccurrences(of: tmp.path, with: "$HOME")))")
    let a = local.appendingPathComponent("Alpha Saga")
    for i in 1...3 { write(png("A1-\(i)"), a.appendingPathComponent("Chapter 1/\(i).png")) }
    for i in 1...2 { write(png("A10-\(i)"), a.appendingPathComponent("Chapter 10/page\(i).png")) }
    let staging = tmp.appendingPathComponent("stage/Ch. 2.5")
    for i in [1, 2, 10] { write(png("A2.5-\(i)"), staging.appendingPathComponent("p\(i).png")) }
    run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", staging.path, a.appendingPathComponent("Ch. 2.5.cbz").path])
    write(png("cover"), a.appendingPathComponent("cover.png"))
    write(Data(#"{"title":"Alpha Saga","author":"A. Writer","genre":["Action"],"status":"ongoing"}"#.utf8), a.appendingPathComponent("details.json"))
    let b = local.appendingPathComponent("Beta Oneshot")
    for i in 1...4 { write(png("B-\(i)"), b.appendingPathComponent("\(i).jpg")) }

    let src = LocalSource()
    let list = try await src.popular(page: 1)
    check(list.series.map(\.title) == ["Alpha Saga", "Beta Oneshot"], "local: series discovered")
    let alpha = try await src.details(list.series[0])
    check(alpha.author == "A. Writer" && alpha.status == .ongoing && alpha.coverURL?.hasSuffix("cover.png") == true, "local: details.json + cover")
    let chs = try await src.chapters(alpha).readingOrder()
    check(chs.map(\.number) == [1, 2.5, 10], "local: chapters in reading order (\(chs.map(\.name)))")
    let cbzPages = try await src.pages(chs[1], of: alpha)
    let names = cbzPages.compactMap { if case .file(let u) = $0 { return u.lastPathComponent } else { return nil } }
    check(names == ["p1.png", "p2.png", "p10.png"], "local: .cbz extracted, natural page order \(names)")
    let cache = (cbzPages.first.flatMap { if case .file(let u) = $0 { return u.path } else { return nil } }) ?? ""
    check(cache.hasPrefix(Paths.cache.path), "local: archive cache is inside Folio's data folder")
    let beta = try await src.details(list.series[1])
    let betaCh = try await src.chapters(beta)
    check(betaCh.count == 1, "local: loose images form one chapter")
    check(try await src.pages(betaCh[0], of: beta).count == 4, "local: loose chapter has 4 pages")
    check(try await src.search("alp", page: 1).series.map(\.title) == ["Alpha Saga"], "local: search")

    // ---------- library
    let lib = Library()
    var e = try await lib.add(alpha)
    check(e.chapters.count == 3 && e.unread == 3, "library: added with 3 unread chapters")
    lib.setProgress(e.id, chapter: chs[0].url, page: 1, of: 3)
    check(lib.entry(e.id)?.resumeChapter?.chapter.url == chs[0].url, "library: resume points to in-progress chapter")
    lib.setProgress(e.id, chapter: chs[0].url, page: 2, of: 3)
    check(lib.entry(e.id)?.chapters.first { $0.chapter.url == chs[0].url }?.read == true, "library: reaching last page marks read")
    check(lib.entry(e.id)?.resumeChapter?.chapter.number == 2.5, "library: resume moves to next unread")
    check(lib.next(after: chs[0].url, in: e.id)?.number == 2.5 && lib.previous(before: chs[2].url, in: e.id)?.number == 2.5,
          "library: next / previous chapter")
    for i in 1...2 { write(png("A11-\(i)"), a.appendingPathComponent("Chapter 11/\(i).png")) }
    let new = try await lib.refresh(e.id)
    e = lib.entry(e.id)!
    check(new == 1 && e.unread == 3, "library: update finds 1 new chapter, read state kept")
    lib.setMode(e.id, .webtoon)
    check(Library().entry(e.id)?.readingMode == .webtoon && Library().entry(e.id)?.chapters.count == 4,
          "library: state persists across restarts")

    // ---------- categories, filters, sorting, incognito, history
    let reading = lib.addCategory("Reading")!
    check(lib.addCategory("reading") == nil && lib.addCategory("  ") == nil, "categories: duplicate and empty names rejected")
    let favs = lib.addCategory("Favorites")!
    lib.setCategories(e.id, [reading.id])
    check(lib.browse(category: reading.id).map(\.id) == [e.id] && lib.browse(category: favs.id).isEmpty && lib.count(in: nil) == 1 && lib.count(in: reading.id) == 1,
          "categories: assign + per-category lists and counts")
    lib.moveCategory(favs.id, by: -1)
    check(lib.settings.categories.map(\.name) == ["Favorites", "Reading"], "categories: reorder")
    lib.settings.filters.unread = true
    check(lib.browse().count == 1, "filter: unread matches a series with unread chapters")
    lib.settings.filters.completed = true
    check(lib.browse().isEmpty, "filter: filters combine (unread AND completed → none for an ongoing series)")
    lib.settings.filters = LibraryFilters()
    check(lib.browse(query: "alp").count == 1 && lib.browse(query: "zzz").isEmpty, "library: text filter")
    let second = try await src.details(list.series[1])
    _ = try await lib.add(second)
    lib.settings.librarySort = .title; lib.settings.sortAscending = true
    check(lib.browse().map(\.series.title) == ["Alpha Saga", "Beta Oneshot"], "sort: title ascending")
    lib.settings.sortAscending = false
    check(lib.browse().map(\.series.title) == ["Beta Oneshot", "Alpha Saga"], "sort: title descending")
    lib.settings.librarySort = .chapterCount
    check(lib.browse().first?.series.title == "Alpha Saga", "sort: by chapter count")
    lib.remove(second.id)
    check(lib.randomEntry() != nil, "library: random pick")

    lib.settings.incognito = true
    let before = lib.entry(e.id)!.chapters
    lib.setProgress(e.id, chapter: chs[2].url, page: 1, of: 2)
    check(lib.entry(e.id)!.chapters == before, "incognito: reading progress is not recorded")
    lib.settings.incognito = false
    lib.setProgress(e.id, chapter: chs[2].url, page: 1, of: 2)
    let resumeBefore = lib.entry(e.id)!.resumeChapter?.chapter.url
    lib.clearHistory()
    check(lib.recents.isEmpty && lib.entry(e.id)!.resumeChapter?.chapter.url == resumeBefore, "history: cleared, but your place in the series is kept")

    lib.deleteCategory(reading.id)
    check(lib.entry(e.id)?.categoryIDs == nil && lib.settings.categories.map(\.name) == ["Favorites"], "categories: deleting removes it from series")

    // an older library file (no category/filter/etc. keys) must still load
    let old = Paths.root.appendingPathComponent("old-library.json")
    try Data(#"{"entries":[],"settings":{"servers":[],"defaultMode":"rightToLeft","preloadPages":3}}"#.utf8).write(to: old)
    let legacy = Library(file: old)
    check(legacy.settings.categories.isEmpty && legacy.settings.libraryDisplay == .grid && legacy.settings.autoUpdateOnLaunch && legacy.settings.defaultMode == .webtoon,
          "compat: old library file loads with new settings defaulted")

    // ---------- OPDS server (Komga-style), Basic auth, PSE streaming + plain download
    let www = tmp.appendingPathComponent("www")
    for i in 0..<3 { write(png("S1-\(i)"), www.appendingPathComponent("pages/b1/\(i).png")) }
    let s2 = tmp.appendingPathComponent("stage/vol2")
    for i in 1...2 { write(png("S2-\(i)"), s2.appendingPathComponent("\(i).png")) }
    run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", s2.path, www.appendingPathComponent("files/b2.cbz").path])
    write(png("cov"), www.appendingPathComponent("cover.png"))
    let atom = #"xmlns="http://www.w3.org/2005/Atom" xmlns:pse="http://vaemendis.net/opds-pse/ns""#
    write(Data("""
    <feed \(atom)><title>Test Komga</title>
      <link rel="search" type="application/opensearchdescription+xml" href="/opds/search.xml"/>
      <entry><title>Stream Story</title><id>s1</id><summary>A test series</summary>
        <link rel="subsection" type="application/atom+xml;profile=opds-catalog;kind=acquisition" href="/opds/series1.xml"/>
        <link rel="http://opds-spec.org/image/thumbnail" type="image/png" href="/cover.png"/></entry>
    </feed>
    """.utf8), www.appendingPathComponent("opds/root.xml"))
    write(Data("""
    <feed \(atom)><title>Stream Story</title><link rel="next" type="application/atom+xml" href="/opds/series1-p2.xml"/>
      <entry><title>Chapter 1 - Start</title><id>b1</id><updated>2026-01-02T03:04:05Z</updated>
        <link rel="http://vaemendis.net/opds-pse/stream" type="image/jpeg" pse:count="3" href="/pages/b1/{pageNumber}.png"/></entry>
    </feed>
    """.utf8), www.appendingPathComponent("opds/series1.xml"))
    write(Data("""
    <feed \(atom)><title>Stream Story p2</title>
      <entry><title>Chapter 2</title><id>b2</id>
        <link rel="http://opds-spec.org/acquisition" type="application/zip" href="/files/b2.cbz"/></entry>
    </feed>
    """.utf8), www.appendingPathComponent("opds/series1-p2.xml"))
    write(Data("""
    <OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/"><Url type="application/atom+xml" template="/opds/root.xml?q={searchTerms}&amp;x=1"/></OpenSearchDescription>
    """.utf8), www.appendingPathComponent("opds/search.xml"))

    let server = """
    import http.server, base64, sys, os
    os.chdir(sys.argv[1])
    class H(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *a): pass
        def do_GET(self):
            if self.headers.get('Authorization') != 'Basic ' + base64.b64encode(b'reader:s3cret').decode():
                self.send_response(401); self.end_headers(); return
            self.path = self.path.split('?')[0]
            return super().do_GET()
    s = http.server.HTTPServer(('127.0.0.1', 0), H)
    print(s.server_address[1], flush=True)
    s.serve_forever()
    """
    let py = Process(); py.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    py.arguments = ["-I", "-c", server, www.path]
    let out = Pipe(); py.standardOutput = out; py.standardError = FileHandle.nullDevice
    try py.run()
    defer { py.terminate() }
    var portLine = Data()
    while !portLine.contains(0x0A) { portLine.append(out.fileHandleForReading.availableData) }
    let port = String(decoding: portLine, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    let base = "http://127.0.0.1:\(port)/opds/root.xml"

    let bad = OPDSSource(OPDSServer(name: "Test", url: base, username: "reader", password: "wrong"))
    do { _ = try await bad.popular(page: 1); check(false, "opds: wrong password rejected") }
    catch { check("\(error)".contains("wrong username or password"), "opds: wrong password rejected") }

    let srv = OPDSServer(name: "Test Komga", url: base, username: "reader", password: "s3cret")
    lib.settings.servers = [srv]
    let opds = lib.opdsSource(srv)
    let ol = try await opds.popular(page: 1)
    check(ol.series.map(\.title) == ["Stream Story"] && ol.series[0].summary == "A test series", "opds: catalog lists series")
    check(try await opds.coverData(ol.series[0]).map { NSImage(data: $0) != nil } == true, "opds: cover fetched with auth")
    check(try await opds.search("story", page: 1).series.first?.title == "Stream Story", "opds: OpenSearch search")
    let oe = try await lib.add(ol.series[0])
    let och = oe.ordered.map(\.chapter)
    check(och.map(\.number) == [1, 2], "opds: chapters across paged feed (\(och.map(\.name)))")
    let (s1, p1) = try await lib.pages(oe.series, och[0])
    check(p1.count == 3 && p1.allSatisfy { if case .remote = $0 { true } else { false } }, "opds: PSE streams 3 pages")
    check(NSImage(data: try await s1.imageData(p1[2])) != nil, "opds: streamed page is a real image")
    let (_, p2) = try await lib.pages(oe.series, och[1])
    check(p2.count == 2, "opds: non-streaming chapter downloaded + extracted")
    try await lib.download(oe.id, chapter: och[0].url)
    let (_, offline) = try await lib.pages(oe.series, och[0])
    check(offline.count == 3 && offline.allSatisfy { if case .file(let u) = $0 { u.path.hasPrefix(Paths.downloads.path) } else { false } },
          "downloads: chapter readable offline from Folio's data folder")
    lib.deleteDownload(oe.id, chapter: och[0].url)
    let (_, back) = try await lib.pages(oe.series, och[0])
    check(back.allSatisfy { if case .remote = $0 { true } else { false } }, "downloads: delete falls back to streaming")

    // ---------- download queue
    lib.settings.parallelDownloads = 2
    lib.setRead(oe.id, chapters: [och[0].url], true)
    check(lib.nextToDownload(oe.id, count: nil) == [och[1].url], "downloads: 'next' skips read chapters")
    lib.setRead(oe.id, chapters: [och[0].url], false)
    check(lib.nextToDownload(oe.id, count: 1) == [och[0].url] && lib.nextToDownload(oe.id, count: nil).count == 2, "downloads: next 1 / all unread")
    lib.enqueueDownloads(oe.id, chapters: lib.nextToDownload(oe.id, count: nil))
    check(lib.downloadsPending > 0, "downloads: queued")
    for _ in 0..<100 where lib.downloadsPending > 0 { try await Task.sleep(for: .milliseconds(100)) }
    check(lib.downloadsPending == 0 && lib.entry(oe.id)!.chapters.allSatisfy(\.downloaded), "downloads: queue finishes, every chapter available offline")
    lib.enqueueDownloads(oe.id, chapters: och.map(\.url))
    check(lib.downloadsPending == 0, "downloads: already-downloaded chapters aren't queued again")
    lib.settings.deleteAfterRead = true
    lib.setRead(oe.id, chapters: [och[0].url], true)
    lib.setBookmarked(oe.id, chapter: och[1].url, true); lib.setRead(oe.id, chapters: [och[1].url], true)
    lib.pruneReadDownloads(keeping: nil)
    let after = lib.entry(oe.id)!.chapters
    check(after.first { $0.chapter.url == och[0].url }?.downloaded == false && after.first { $0.chapter.url == och[1].url }?.downloaded == true,
          "downloads: delete-after-read removes read chapters but keeps bookmarked ones")
    let usage = lib.storageUsage()
    check(usage.downloads > 0 && usage.cache > 0, "storage: usage reported (downloads \(usage.downloads / 1024) KB, cache \(usage.cache / 1024) KB)")
    lib.clearCache()
    check(lib.storageUsage().cache == 0, "storage: cache cleared")
    lib.clearAllDownloads()
    check(lib.storageUsage().downloads == 0 && lib.entry(oe.id)!.chapters.allSatisfy { !$0.downloaded }, "storage: all downloads removed")

    // ---------- nothing written outside $HOME/Library/Application Support/Folio (besides test fixtures)
    let stray = (FileManager.default.enumerator(at: tmp, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
        .filter { !$0.path.hasPrefix(Paths.root.path) && !$0.path.hasPrefix(tmp.appendingPathComponent("stage").path)
            && !$0.path.hasPrefix(www.path) && $0.path != tmp.appendingPathComponent("Library").path
            && $0.path != tmp.appendingPathComponent("Library/Application Support").path }
    check(stray.isEmpty, "privacy: no files written outside Folio's data folder \(stray.map(\.lastPathComponent))")
}

// ---------- real Android extensions through the embedded engine (pass --extensions)
@MainActor func extensions() async throws {
    let engine = ExtensionEngine.shared
    let realTmp = URL(fileURLWithPath: NSTemporaryDirectory())
    try await engine.ensureRunning()
    check(engine.state == .running, "engine: started on a random local port")
    var anon = URLRequest(url: engine._baseForTesting.appendingPathComponent("api/graphql"))
    anon.httpMethod = "POST"; anon.setValue("application/json", forHTTPHeaderField: "Content-Type")
    anon.httpBody = Data(#"{"query":"{ extensions { totalCount } }"}"#.utf8)
    let code = ((try? await URLSession.folioLocal.data(for: anon))?.1 as? HTTPURLResponse)?.statusCode ?? 0
    check(code == 401, "engine: requests without Folio's per-launch login are refused (HTTP \(code))")
    let repo = try await engine.addRepo("https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.min.json")
    let all = try await engine.refreshExtensions()
    check(all.count > 500, "engine: repo \(repo.name) lists \(all.count) extensions")
    guard let md = all.first(where: { $0.pkgName.hasSuffix(".mangadex") }) else { check(false, "engine: MangaDex extension present"); return }
    try await engine.perform(.install, md.pkgName)
    check(try await engine.extensions().first { $0.pkgName == md.pkgName }?.installed == true, "engine: installed \(md.name) \(md.version)")
    let lib = Library()
    try await lib.syncExtensionSources()
    let en = lib.visibleExtensionSources.first { $0.info.name == "MangaDex" && $0.info.lang == "en" }
    check(en != nil && lib.visibleExtensionSources.allSatisfy { ["en", "all"].contains($0.info.lang) },
          "library: extension sources filtered to your languages (\(lib.visibleExtensionSources.count) shown of \(lib.settings.extensionSources.count))")
    guard let src = en else { return }
    let pop = try await src.popular(page: 1)
    check(!pop.series.isEmpty, "source: popular list (\(pop.series.count) series, more: \(pop.hasNextPage))")
    let fl = try await src.filters()
    check(!fl.isEmpty, "filters: MangaDex describes \(fl.count) filter controls")
    var withGenre = fl
    func flatten(_ f: [SourceFilter]) -> [SourceFilter] { f.flatMap { if case .group(let k) = $0.kind { return flatten(k) } else { return [$0] } } }
    check(flatten(fl).contains { if case .tristate = $0.kind { return true } else { return false } }, "filters: includes tri-state controls (tags)")
    // include the first tri-state tag found and make sure the results change
    for (i, f) in withGenre.enumerated() {
        if case .group(var kids) = f.kind, let j = kids.firstIndex(where: { if case .tristate = $0.kind { return true } else { return false } }) {
            kids[j].kind = .tristate(.include); withGenre[i].kind = .group(kids); break
        }
    }
    check(withGenre.activeCount == 1 && withGenre.reset().activeCount == 0, "filters: active count and reset")
    let filtered = try await src.search("", filters: withGenre, page: 1)
    check(!filtered.series.isEmpty && filtered.series.map(\.id) != pop.series.map(\.id), "filters: a tag filter returns a different list (\(filtered.series.count) series)")
    // Tachiyomi backup import: build a tiny .tachibk (gzip'd protobuf) by hand and restore it through the engine.
    func varint(_ v: UInt64) -> [UInt8] { var v = v, o: [UInt8] = []; repeat { var b = UInt8(v & 0x7f); v >>= 7; if v != 0 { b |= 0x80 }; o.append(b) } while v != 0; return o }
    func f(_ n: Int, varint v: UInt64) -> [UInt8] { varint(UInt64(n << 3)) + varint(v) }
    func f(_ n: Int, string v: String) -> [UInt8] { varint(UInt64(n << 3 | 2)) + varint(UInt64(v.utf8.count)) + Array(v.utf8) }
    func f(_ n: Int, bytes v: [UInt8]) -> [UInt8] { varint(UInt64(n << 3 | 2)) + varint(UInt64(v.count)) + v }
    let chapters = (1...3).map { i in f(16, bytes: f(1, string: "/chapter/imp\(i)") + f(2, string: "Imported Chapter \(i)") + f(4, varint: i == 1 ? 1 : 0) + f(8, varint: 1_700_000_000_000)) }
    let manga = f(1, varint: UInt64(src.info.id) ?? 0) + f(2, string: "/manga/imported-test") + f(3, string: "Imported Test Series") + f(100, varint: 1) + Array(chapters.joined())
    let proto = Data(f(1, bytes: manga))
    let gz = tmp.appendingPathComponent("bk.proto"); try proto.write(to: gz)
    let gp = Process(); gp.executableURL = URL(fileURLWithPath: "/usr/bin/gzip"); gp.arguments = ["-kf", gz.path]; try gp.run(); gp.waitUntilExit()
    let imported = try await engine.importTachiyomiBackup(try Data(contentsOf: gz.appendingPathExtension("gz")))
    let got = imported.first { $0.entry.series.title == "Imported Test Series" }
    check(got != nil && got!.entry.chapters.count == 3 && got!.entry.chapters.filter(\.read).count == 1,
          "import: a Tachiyomi backup restores with its chapters and read marks (\(imported.count) series)")
    let lib3 = Library(file: tmp.appendingPathComponent("imp.json"))
    check(got.map { lib3.importSeries([$0]).added == 1 && lib3.importSeries([$0]).skipped == 1 } == true, "import: lands in the library once, never twice")
    let prefs = try await src.preferences()
    check(!prefs.isEmpty, "preferences: MangaDex describes \(prefs.count) settings (\(prefs.map(\.title).prefix(4).joined(separator: ", ")))")
    func toggleState(_ p: SourcePreference) -> Bool? { if case .toggle(let b) = p.kind { return b } else { return nil } }
    if let t = prefs.first(where: { toggleState($0) != nil }), let was = toggleState(t) {
        var flipped = t; flipped.kind = .toggle(!was)
        let after = try await src.setPreference(flipped)
        check(after.first { $0.position == t.position }?.kind == .toggle(!was), "preferences: toggling \"\(t.title)\" is saved by the engine")
        _ = try await src.setPreference(t)
        check((try await src.preferences()).first { $0.position == t.position }?.kind == .toggle(was), "preferences: and can be put back")
    } else { check(false, "preferences: a toggle setting exists") }
    let found = try await src.search("one", page: 1)
    check(!found.series.isEmpty, "source: search works (\(found.series.count) results)")
    let cover = try await src.coverData(pop.series[0])
    check(cover.flatMap { NSImage(data: $0) } != nil, "source: cover image loads")
    var target: LibraryEntry?
    for s in pop.series.prefix(8) {
        let e = try await lib.add(s)
        if !e.chapters.isEmpty { target = e; break }
        lib.remove(e.id)
    }
    guard let e = target else { check(false, "library: a series with chapters"); return }
    check(e.series.author != nil || e.series.summary != nil, "library: added \"\(e.series.title.prefix(40))\" with details + \(e.chapters.count) chapters")
    let first = e.ordered[0].chapter
    let (s2, pages) = try await lib.pages(e.series, first)
    check(!pages.isEmpty, "reader: \(first.name) has \(pages.count) pages")
    check(NSImage(data: try await s2.imageData(pages[0])) != nil, "reader: page 1 is a real image")
    try await lib.download(e.id, chapter: first.url)
    check(lib.entry(e.id)?.chapters.first { $0.chapter.url == first.url }?.downloaded == true, "downloads: chapter saved for offline reading")
    let leaked = ((try? FileManager.default.contentsOfDirectory(atPath: realTmp.path)) ?? []).filter { $0.lowercased().contains("tachidesk") }
    check(leaked.isEmpty, "privacy: engine wrote nothing to the system temp folder")
    let engineFiles = (try? FileManager.default.contentsOfDirectory(atPath: Paths.root.appendingPathComponent("Engine").path)) ?? []
    check(engineFiles.contains("database.mv.db") && engineFiles.contains("extensions"), "privacy: engine database + extensions inside Folio's data folder")
    engine.stop()
    try await Task.sleep(for: .seconds(2))
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-f", Paths.root.path]
    p.standardOutput = FileHandle.nullDevice; try p.run(); p.waitUntilExit()
    check(p.terminationStatus != 0, "engine: fully stopped (no leftover Java process)")
}

// ---------- network layer: scheduler, retry, disk cache, Cloudflare detection
actor Recorder {
    var order: [String] = [], active = 0, peak = 0
    func enter() { active += 1; peak = max(peak, active) }
    func leave(_ n: String) { active -= 1; order.append(n) }
}
final class Flaky: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var script: [(Int, String)] = []
    nonisolated(unsafe) static var hits = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, body) = Flaky.script.isEmpty ? (200, "ok") : Flaky.script.removeFirst()
        Flaky.hits += 1
        let r = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: code == 429 ? ["Retry-After": "0"] : [:])!
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func network() async throws {
    // scheduler: concurrency cap
    let s2 = FetchScheduler(limit: 2), rec = Recorder()
    await withTaskGroup(of: Void.self) { g in
        for i in 0..<6 { g.addTask { _ = try? await s2.run(priority: .normal) { await rec.enter(); try await Task.sleep(for: .milliseconds(40)); await rec.leave("\(i)") } } }
    }
    let peak = await rec.peak, done = await rec.order.count
    check(peak == 2 && done == 6, "net: scheduler never runs more than its limit (peak \(peak))")

    // scheduler: high first (newest first), then low oldest-first; cancel + promote while queued
    let s1 = FetchScheduler(limit: 1), r2 = Recorder()
    let gate = Task { try await s1.run(priority: .normal) { try await Task.sleep(for: .milliseconds(250)) } }
    try await Task.sleep(for: .milliseconds(30))
    func queue(_ n: String, _ p: FetchPriority, key: String? = nil) -> Task<Void, Error> {
        Task { try await s1.run(key: key, priority: p) { await r2.leave(n) } }
    }
    let a = queue("lowA", .low); try await Task.sleep(for: .milliseconds(15))
    let b = queue("lowB", .low, key: "B"); try await Task.sleep(for: .milliseconds(15))
    let c = queue("highC", .high); try await Task.sleep(for: .milliseconds(15))
    let d = queue("highD", .high); try await Task.sleep(for: .milliseconds(15))
    let x = queue("cancelled", .high); try await Task.sleep(for: .milliseconds(15))
    x.cancel()
    await s1.promote(key: "B", to: .high)
    _ = try? await gate.value
    for t in [a, b, c, d] { try await t.value }
    let order = await r2.order
    check(order == ["lowB", "highD", "highC", "lowA"],
          "net: scheduler order — high newest-first, promoted request jumps ahead, low oldest-first (\(order))")
    check(!order.contains("cancelled"), "net: a cancelled queued request never runs")

    // retry
    let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [Flaky.self]
    let fs = URLSession(configuration: cfg)
    let u = URLRequest(url: URL(string: "http://example.test/x")!)
    Flaky.script = [(503, "x"), (429, "x")]; Flaky.hits = 0
    let (d1, h1) = try await Net.data(for: u, session: fs)
    check(h1.statusCode == 200 && String(decoding: d1, as: UTF8.self) == "ok" && Flaky.hits == 3, "net: retries 503/429 then succeeds (\(Flaky.hits) attempts)")
    Flaky.script = [(404, "no")]; Flaky.hits = 0
    check(try await Net.data(for: u, session: fs).1.statusCode == 404 && Flaky.hits == 1, "net: 404 isn't retried")
    Flaky.script = [(503, "<title>Just a moment...</title><div id=cf-chl>")]; Flaky.hits = 0
    var sawCF = false
    do { _ = try await Net.data(for: u, session: fs) } catch is CloudflareError { sawCF = true }
    check(sawCF && Flaky.hits == 1, "net: Cloudflare check page is recognised and not retried")
    check(CloudflareError.matches("Cloudflare bypass failed") && !CloudflareError.matches("Manga not found"), "net: Cloudflare wording detection")

    // disk cache
    let dc = DiskCache(dir: tmp.appendingPathComponent("dc"), limit: 3000)
    let blob = Data(repeating: 7, count: 1000)
    dc.set("a", blob); try await Task.sleep(for: .milliseconds(20))
    dc.set("b", blob); try await Task.sleep(for: .milliseconds(20))
    dc.set("c", blob)
    check(dc.get("a") != nil && dc.byteCount == 3000, "net: disk cache stores and returns bytes")
    dc.set("d", blob)
    check(dc.get("a") == nil && dc.get("d") != nil && dc.byteCount <= 3000, "net: disk cache evicts least-recently-used past its limit")
    check(dc.get("d", maxAge: -1) == nil && DiskCache(dir: tmp.appendingPathComponent("dc"), limit: 3000).get("d") != nil,
          "net: max age expires entries; cache survives relaunch")
    dc.clear(); check(dc.byteCount == 0 && dc.get("d") == nil, "net: disk cache clears")

    // image pipeline: only real images are cached
    let img = png("net")
    var loads = 0
    nonisolated(unsafe) var counter = 0
    func load(_ data: Data) async throws -> Data { try await ImageFetch.data(key: "t|\(data.count)") { counter += 1; return data } }
    _ = try await load(img); _ = try await load(img)
    loads = counter
    check(loads == 1, "net: second fetch of an image comes from disk (network hit \(loads)×)")
    var cfImage = false
    do { _ = try await ImageFetch.data(key: "t|html") { Data("<html>Just a moment... cloudflare</html>   ".utf8) } } catch is CloudflareError { cfImage = true }
    check(cfImage && DiskCache.shared.get("t|html") == nil, "net: an HTML challenge page is never cached and surfaces as a Cloudflare error")
}

// ---------- saved vs read history
@MainActor func savedVsHistory() async throws {
    let lib = Library(file: tmp.appendingPathComponent("saved-test.json"))
    let s = Series(sourceID: "local", url: "Alpha Saga", title: "Alpha Saga")
    let e = try await lib.track(s)
    check(lib.contains(s) == false && lib.browse().isEmpty && lib.count(in: nil) == 0, "saved: reading alone doesn't put a series in the library")
    lib.setProgress(e.id, chapter: e.chapters[0].chapter.url, page: 0, of: 5)
    check(lib.recents.map(\.id) == [e.id], "saved: it still shows in Recent")
    try await lib.add(s)
    check(lib.contains(s) && lib.browse().map(\.id) == [e.id] && lib.entry(e.id)?.lastRead != nil, "saved: saving it adds it to the library and keeps its progress")
    lib.remove(e.id)
    check(!lib.contains(s) && lib.browse().isEmpty && lib.recents.count == 1, "saved: removing a read series keeps it in history only")
    lib.forget(e.id)
    check(lib.entry(e.id) == nil, "saved: forgetting an unsaved series deletes it")
    let e2 = try await lib.add(s)
    lib.remove(e2.id)
    check(lib.entry(e2.id) == nil, "saved: removing a never-read series deletes it")
    try await lib.add(s); lib.setProgress(s.id, chapter: lib.entry(s.id)!.chapters[0].chapter.url, page: 0, of: 5)
    lib.clearHistory()
    check(lib.contains(s) && lib.recents.isEmpty, "saved: clearing history keeps saved series")
    check(Library(file: tmp.appendingPathComponent("saved-test.json")).contains(s), "saved: survives relaunch")

    // remembered chapter state
    let cu = lib.entry(s.id)!.chapters[0].chapter.url
    lib.setPageAspects(s.id, chapter: cu, [0.5, 0.52, 0.5])
    check(Library(file: tmp.appendingPathComponent("saved-test.json")).pageAspects(s.id, chapter: cu) == [0.5, 0.52, 0.5], "remembered: page shapes survive relaunch")
    lib.forgetPages(s.id, chapter: cu)
    check(lib.pageAspects(s.id, chapter: cu) == nil && lib.entry(s.id)!.chapters[0].pageURLs == nil, "remembered: forgetting a chapter clears its page list and shapes")
}

// ---------- library sorting
@MainActor func sorting() async throws {
    let lib = Library(file: tmp.appendingPathComponent("sort-test.json"))
    func entry(_ title: String, chapters: Int, read: Int) -> LibraryEntry {
        var e = LibraryEntry(series: Series(sourceID: "local", url: title, title: title),
                             chapters: (1...chapters).map { ChapterState(chapter: Chapter(url: "c\($0)", name: "Chapter \($0)")) })
        for i in 0..<read { e.chapters[i].read = true }
        e.added = Date(timeIntervalSince1970: Double(chapters * 1000))
        return e
    }
    lib._replaceEntries([entry("Bravo", chapters: 10, read: 9), entry("alpha", chapters: 30, read: 0), entry("Charlie", chapters: 5, read: 5)])
    func order(_ s: LibrarySort, asc: Bool) -> [String] {
        lib.settings.librarySort = s; lib.settings.sortAscending = asc
        return lib.browse().map(\.series.title)
    }
    check(order(.title, asc: true) == ["alpha", "Bravo", "Charlie"], "sort: alphabetical a → z (case-insensitive)")
    check(order(.title, asc: false) == ["Charlie", "Bravo", "alpha"], "sort: alphabetical z → a")
    check(order(.chapterCount, asc: false) == ["alpha", "Bravo", "Charlie"], "sort: chapter count, most first")
    check(order(.chapterCount, asc: true) == ["Charlie", "Bravo", "alpha"], "sort: chapter count, fewest first")
    check(order(.unread, asc: false) == ["alpha", "Bravo", "Charlie"], "sort: unread chapters, most first")
    check(order(.progress, asc: false) == ["Charlie", "Bravo", "alpha"], "sort: reading progress, most read first")
    check(order(.added, asc: false) == ["alpha", "Bravo", "Charlie"], "sort: date added, newest first")
    check(LibrarySort.title.naturalAscending && !LibrarySort.unread.naturalAscending, "sort: each sort starts in its natural direction")
}

// ---------- backup / restore
@MainActor func backups() async throws {
    let lib = Library(file: tmp.appendingPathComponent("bk-a.json"))
    var e = LibraryEntry(series: Series(sourceID: "local", url: "bk", title: "Backed Up"),
                         chapters: (1...3).map { ChapterState(chapter: Chapter(url: "c\($0)", name: "Chapter \($0)")) })
    e.chapters[0].read = true; e.chapters[1].lastPage = 7; e.chapters[2].bookmarked = true
    lib._replaceEntries([e])
    lib.settings.categories = [LibraryCategory(name: "Favourites")]
    lib.settings.gridSize = 222
    lib.setCover(e.id, jpeg: Data([0xff, 0xd8, 0xff, 0xd9]))
    let data = try lib.backupData()
    let other = Library(file: tmp.appendingPathComponent("bk-b.json"))
    check(other.entries.isEmpty, "backup: a fresh library starts empty")
    let n = try other.restore(data)
    let r = other.entry(e.id)
    check(n == 1 && r?.chapters[0].read == true && r?.chapters[1].lastPage == 7 && r?.chapters[2].bookmarked == true, "backup: progress, read marks and bookmarks restore")
    check(other.settings.categories.first?.name == "Favourites" && other.settings.gridSize == 222, "backup: categories and settings restore")
    check(r?.customCover.map { FileManager.default.fileExists(atPath: $0) } == true, "backup: a picked cover comes back")
    var threw = false
    do { try other.restore(Data("{\"nope\":1}".utf8)) } catch { threw = true }
    check(threw && other.entries.count == 1, "backup: a wrong file is refused and changes nothing")
    let auto = lib.writeAutoBackup(keep: 2)
    _ = lib.writeAutoBackup(keep: 2)
    check(auto != nil && lib.latestAutoBackup != nil, "backup: automatic backup is written")
}

// ---------- double-page spreads
func spreads() {
    let wide: Set<Int> = [4]
    let l = PageSpreads.layout(count: 8, isWide: { wide.contains($0) }, firstAlone: true)
    check(l == [[0], [1, 2], [3], [4], [5, 6], [7]], "spreads: cover alone, pairs after it, a wide page alone and pairing resumes (\(l))")
    let l2 = PageSpreads.layout(count: 5, isWide: { _ in false }, firstAlone: false)
    check(l2 == [[0, 1], [2, 3], [4]], "spreads: without a cover, pairs start at page 1; the odd last page is alone")
    check(PageSpreads.spread(containing: 6, in: l) == 4 && PageSpreads.spread(containing: 0, in: l) == 0, "spreads: finds the spread holding a page")
    check(PageSpreads.layout(count: 0, isWide: { _ in false }, firstAlone: true).isEmpty, "spreads: an empty chapter has none")
    let old = try? JSONDecoder().decode(FolioSettings.self, from: Data("{}".utf8))
    check(old?.doublePage == false && old?.doubleFirstAlone == true && old?.splitWidePages == false, "spreads: older files load with single-page defaults")
}

// ---------- update schedule
@MainActor func updates() async throws {
    let lib = Library(file: tmp.appendingPathComponent("upd.json"))
    func entry(_ t: String, _ status: SeriesStatus, read: Int, of n: Int, cats: [String]? = nil) -> LibraryEntry {
        var s = Series(sourceID: "local", url: t, title: t); s.status = status
        var e = LibraryEntry(series: s, chapters: (1...n).map { ChapterState(chapter: Chapter(url: "c\($0)", name: "Chapter \($0)")) })
        for i in 0..<read { e.chapters[i].read = true }
        e.categoryIDs = cats
        return e
    }
    lib._replaceEntries([entry("Ongoing", .ongoing, read: 2, of: 5), entry("Done", .completed, read: 3, of: 3),
                         entry("Fresh", .ongoing, read: 0, of: 4), entry("Caught up", .ongoing, read: 4, of: 4, cats: ["sleep"])])
    check(lib.updatable().count == 4, "updates: with no rules every saved series is checked")
    lib.settings.updateRules.skipCompleted = true
    check(Set(lib.updatable().map(\.series.title)) == ["Ongoing", "Fresh", "Caught up"], "updates: skip completed")
    lib.settings.updateRules.skipWithUnread = true
    check(Set(lib.updatable().map(\.series.title)) == ["Caught up"], "updates: skip series with unread chapters")
    lib.settings.updateRules = UpdateRules(); lib.settings.updateRules.skipNotStarted = true
    check(Set(lib.updatable().map(\.series.title)) == ["Ongoing", "Done", "Caught up"], "updates: skip series not started")
    lib.settings.updateRules = UpdateRules(); lib.settings.updateRules.excludedCategories = ["sleep"]
    check(!lib.updatable().contains { $0.series.title == "Caught up" }, "updates: skip a category")
    let now = Date()
    lib.settings.lastAutoUpdate = now.addingTimeInterval(-3600)
    lib.settings.updateInterval = .daily
    check(!lib.updateDue(now: now), "schedule: daily isn't due an hour after a check")
    lib.settings.lastAutoUpdate = now.addingTimeInterval(-25 * 3600)
    check(lib.updateDue(now: now), "schedule: daily is due after 25 hours")
    lib.settings.updateInterval = .launch
    check(!lib.updateDue(now: now) && lib.updateDue(now: now, atLaunch: true), "schedule: 'when Folio opens' only fires at launch")
    lib.settings.updateInterval = .off
    check(!lib.updateDue(now: now, atLaunch: true), "schedule: never means never")
    let old = try JSONDecoder().decode(FolioSettings.self, from: Data(#"{"autoUpdateOnLaunch":false}"#.utf8))
    check(old.updateInterval == .off && FolioSettings().updateInterval == .launch, "schedule: an older 'off' setting is respected")
}

// ---------- migration
@MainActor func migration() async throws {
    func st(_ name: String, _ n: Double, read: Bool = false, page: Int = 0, mark: Bool = false) -> ChapterState {
        var c = ChapterState(chapter: Chapter(url: name, name: name, number: n)); c.read = read; c.lastPage = page; c.bookmarked = mark; return c
    }
    let old = [st("Ch. 1", 1, read: true), st("Ch. 2", 2, read: true, mark: true), st("Ch. 3", 3, page: 9), st("Special", -1, read: true)]
    let new = [st("Chapter 1", 1), st("Chapter 2", 2), st("Chapter 3", 3), st("Chapter 4", 4), st("Special", -1)]
    let r = Library.transferProgress(from: old, to: new)
    check(r[0].read && r[1].read && r[1].bookmarked, "migrate: read marks and bookmarks follow the chapter number")
    check(!r[2].read && r[2].lastPage == 9, "migrate: partly-read progress carries over")
    check(!r[3].read && r[3].lastPage == 0, "migrate: chapters the old source never had stay unread")
    check(r[4].read, "migrate: unnumbered chapters match by name")
    let dup = Library.transferProgress(from: [st("a", 5, read: true), st("b", 5)], to: [st("x", 5)])
    check(dup[0].read, "migrate: two translations of one chapter — read in either counts as read")
}

// ---------- reader settings
@MainActor func readerSettings() async throws {
    let lib = Library(file: tmp.appendingPathComponent("reader-test.json"))
    var e = LibraryEntry(series: Series(sourceID: "local", url: "r", title: "R"),
                         chapters: (1...4).map { ChapterState(chapter: Chapter(url: "c\($0)", name: "Chapter \($0)")) })
    e.chapters[1].read = true   // c2 read; c1, c3, c4 unread
    lib._replaceEntries([e])
    let id = e.series.id
    check(lib.next(after: "c1", in: id)?.url == "c2", "chapters: next follows order by default")
    check(lib.next(after: "c1", in: id, skipRead: true)?.url == "c3", "chapters: next skips read chapters")
    check(lib.previous(before: "c3", in: id, skipRead: true)?.url == "c1", "chapters: previous skips read chapters")
    check(lib.next(after: "c4", in: id, skipRead: true) == nil, "chapters: no next at the end")
    check(TapZones.standard.action(x: 0.1, y: 0.5) == .back && TapZones.standard.action(x: 0.5, y: 0.5) == .controls && TapZones.standard.action(x: 0.9, y: 0.5) == .forward, "tap zones: thirds")
    check(TapZones.edges.action(x: 0.3, y: 0.5) == .controls && TapZones.edges.action(x: 0.95, y: 0.5) == .forward, "tap zones: edges leave a wide middle")
    check(TapZones.lShaped.action(x: 0.5, y: 0.9) == .forward && TapZones.lShaped.action(x: 0.1, y: 0.5) == .back, "tap zones: L-shaped")
    check(TapZones.off.action(x: 0.05, y: 0.5) == .controls, "tap zones: off never turns pages")
    // crop borders: a white page with a black box in the middle
    func page(_ draw: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: 400, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
        draw(ctx)
        return ctx.makeImage()!
    }
    let boxed = page { c in
        c.setFillColor(gray: 0.1, alpha: 1); c.fill(CGRect(x: 80, y: 120, width: 240, height: 300))
        c.setFillColor(gray: 0.6, alpha: 1); c.fill(CGRect(x: 120, y: 200, width: 80, height: 80))
    }
    let r = BorderCrop.content(of: boxed)
    check(r != nil && abs(r!.minX - 0.2) < 0.03 && abs(r!.width - 0.6) < 0.05 && abs(r!.height - 0.5) < 0.05, "crop: finds the content box inside white margins (\(String(describing: r)))")
    let full = page { c in c.setFillColor(gray: 0.3, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: 400, height: 600)) }
    check(BorderCrop.content(of: full) == nil, "crop: a full-bleed page is left alone")
    let blank = page { _ in }
    check(BorderCrop.content(of: blank) == nil, "crop: a blank page is left alone")
    let lib2 = Library(file: tmp.appendingPathComponent("cover-test.json"))
    let s2 = Series(sourceID: "local", url: "cv", title: "CV", coverURL: "https://x/y.jpg")
    lib2._replaceEntries([LibraryEntry(series: s2, chapters: [])])
    lib2.setCover(s2.id, jpeg: Data([0xff, 0xd8, 0xff, 0xd9]))
    let cp = lib2.entry(s2.id)?.series.coverURL ?? ""
    check(cp.hasPrefix("/") && FileManager.default.fileExists(atPath: cp) && lib2.entry(s2.id)?.customCover == cp, "cover: set from a page, stored on disk")
    let old = try JSONDecoder().decode(FolioSettings.self, from: Data("{}".utf8))
    check(!old.cropBorders && old.tapZones == .standard && !old.skipReadChapters && !old.invertTapZones, "settings: older files load with reader defaults")
}

// ---------- data safety (audit wave 2, section 1)
@MainActor func dataSafety() async throws {
    let box = Paths.root.appendingPathComponent("SafetyTest", isDirectory: true)
    try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
    func chapter(_ n: Int) -> ChapterState {
        var c = ChapterState(chapter: Chapter(url: "c\(n)", name: "Chapter \(n)", number: Double(n), uploaded: Date(), scanlator: "s", webURL: "w"))
        c.read = n == 1; c.lastPage = 2; c.pageCount = 8; c.pageURLs = ["https://x/1"]; c.pagesFetched = Date(); c.pageAspects = [1.5]; c.lastRead = Date(); c.downloaded = n == 2
        return c
    }
    var e1 = LibraryEntry(series: Series(sourceID: "local", url: "one", title: "One", author: "a", artist: "b", summary: "s", genres: ["g"], status: .ongoing, coverURL: "c"),
                          chapters: [chapter(1), chapter(2)], lastChecked: Date())
    e1.readingMode = .rightToLeft; e1.categoryIDs = ["x"]; e1.note = "n"; e1.saved = true; e1.customCover = "/c.jpg"; e1.lastRead = Date()
    let e2 = LibraryEntry(series: Series(sourceID: "local", url: "two", title: "Two"), chapters: [chapter(1)])
    let seed = Library(file: box.appendingPathComponent("seed-safety.json"))
    seed._replaceEntries([e1, e2])
    seed.settings.servers = [OPDSServer(name: "S", url: "http://x", username: "u", password: "p")]
    seed.settings.categories = [LibraryCategory(name: "Cat")]
    seed.settings.extensionSources = [ExtensionSourceInfo(id: "1", name: "n", lang: "en", displayName: "d", supportsLatest: true, nsfw: false, iconPath: "i", isConfigurable: true)]
    seed.settings.filters.unread = true
    seed.save()
    let good = try Data(contentsOf: box.appendingPathComponent("seed-safety.json"))
    let root = try JSONSerialization.jsonObject(with: good)

    // Every key of every persisted model, dropped one at a time. Identity keys cost only their own row.
    let identity: Set<String> = ["series", "url", "sourceID", "chapter", "id"]
    var paths: [[Any]] = []
    func walk(_ o: Any, _ path: [Any]) {
        if let d = o as? [String: Any] { for (k, v) in d { paths.append(path + [k]); walk(v, path + [k]) } }
        else if let a = o as? [Any] { for (i, v) in a.enumerated() { walk(v, path + [i]) } }
    }
    walk(root, [])
    func remove(_ o: Any, _ p: ArraySlice<Any>) -> Any {
        guard let k = p.first else { return o }
        if let key = k as? String, var d = o as? [String: Any] { if p.count == 1 { d[key] = nil } else { d[key] = remove(d[key]!, p.dropFirst()) }; return d }
        if let i = k as? Int, var a = o as? [Any] { a[i] = remove(a[i], p.dropFirst()); return a }
        return o
    }
    var bad: [String] = [], n = 0
    for (i, p) in paths.enumerated() {
        let key = p.last as? String ?? ""
        let mutated = remove(root, p[...])
        let f = box.appendingPathComponent("drop-\(i).json")
        try JSONSerialization.data(withJSONObject: mutated).write(to: f)
        let lib = Library(file: f)
        n += 1
        let path = p.map { "\($0)" }.joined(separator: ".")
        if lib.loadProblem != nil { bad.append("\(path): whole file rejected"); continue }
        if p.count == 1 { continue }       // dropping the whole entries/settings list is a different case
        if identity.contains(key) { if lib.entries.count < 1 { bad.append("\(path): lost everything") } }
        else if lib.entries.count != 2 { bad.append("\(path): lost entries") }
        else if p.count > 3, (p[0] as? String) == "entries", (p[2] as? String) == "chapters", lib.entries[p[1] as! Int].chapters.count != (p[1] as! Int == 0 ? 2 : 1) { bad.append("\(path): lost chapters") }
    }
    check(bad.isEmpty, "F1: dropping any one of \(n) keys never loses the library\(bad.isEmpty ? "" : " — " + bad.prefix(5).joined(separator: "; "))")

    // An unknown enum value (after a downgrade) must not fail the file either.
    var text = String(decoding: good, as: UTF8.self)
    text = text.replacingOccurrences(of: "\"rightToLeft\"", with: "\"sideways\"").replacingOccurrences(of: "\"ongoing\"", with: "\"paused\"")
    let fe = box.appendingPathComponent("enum.json"); try text.write(to: fe, atomically: true, encoding: .utf8)
    let le = Library(file: fe)
    check(le.entries.count == 2 && le.loadProblem == nil && le.entries[0].readingMode == nil, "F1: unknown enum values fall back instead of failing")

    // One garbage entry is skipped; the others survive and a copy of the file is kept.
    var obj = root as! [String: Any]
    var arr = obj["entries"] as! [Any]; arr.insert("garbage", at: 1); arr.append(["series": 5]); obj["entries"] = arr
    let fb = box.appendingPathComponent("badentry.json"); try JSONSerialization.data(withJSONObject: obj).write(to: fb)
    let lb = Library(file: fb)
    let kept1 = (try? FileManager.default.contentsOfDirectory(atPath: box.path))?.filter { $0.hasPrefix("library.corrupt-") }.count ?? 0
    check(lb.entries.count == 2 && lb.skippedOnLoad == 2 && lb.loadProblem == nil, "F1: unreadable entries are skipped, the rest load")

    // A file that can't be parsed at all: not loaded, not overwritten, copy kept, saving resumes only on request.
    let fc = box.appendingPathComponent("library.json")
    try Data("{ not json".utf8).write(to: fc)
    let lc = Library(file: fc)
    lc.settings.showBadges.toggle()          // would normally schedule a save
    lc.save()
    check(lc.loadProblem != nil && ((try? Data(contentsOf: fc)) ?? Data()) == Data("{ not json".utf8), "F1: an unreadable file is never overwritten")
    let kept2 = (try? FileManager.default.contentsOfDirectory(atPath: box.path))?.filter { $0.hasPrefix("library.corrupt-") }.count ?? 0
    check(kept2 > kept1, "F1: a library.corrupt-<date>.json copy is kept")
    lc.startFresh()
    check(lc.loadProblem == nil && ((try? Data(contentsOf: fc)) ?? Data()) != Data("{ not json".utf8), "F1: after the user chooses, saving resumes")

    // library.json.bak holds the previous version after each overwrite.
    let fk = box.appendingPathComponent("bak.json")
    let lk = Library(file: fk)
    lk._replaceEntries([e1]); lk._replaceEntries([e1, e2])
    let bakCopy = box.appendingPathComponent("bak-copy.json")
    try FileManager.default.copyItem(at: fk.appendingPathExtension("bak"), to: bakCopy)
    check(Library(file: bakCopy).entries.count == 1, "F1: library.json.bak holds the previous version")

    // ---------- downloads: F4, F5, F7, F8
    let safe = Paths.localLibrary.appendingPathComponent("Safe Series")
    for c in 1...4 { for i in 1...3 { write(png("S\(c)-\(i)"), safe.appendingPathComponent("Chapter \(c)/\(i).png")) } }
    let dl = Library(file: box.appendingPathComponent("dl.json"))
    let sp = try await dl.local.popular(page: 1).series.first { $0.title == "Safe Series" }!
    let se = try await dl.add(sp)
    let ord = se.ordered.map(\.chapter.url)
    dl.setRead(se.id, chapters: [ord[0], ord[2]], true)
    check(dl.nextToDownload(se.id, count: nil) == [ord[1], ord[3]], "F4: 'All unread' leaves out read chapters after the first unread")
    try await dl.download(se.id, chapter: ord[1])
    let backup = try dl.backupData()
    try dl.restore(backup)
    check(dl.entry(se.id)!.chapters.first { $0.chapter.url == ord[1] }!.downloaded, "F5: restore keeps the downloaded flag when the files are on disk")
    try dl.restore(backup)
    let ddir = Paths.downloads.appendingPathComponent(Paths.hash(se.id)).appendingPathComponent(Paths.hash(ord[1]))
    try? FileManager.default.removeItem(at: ddir.appendingPathComponent(".complete"))   // an interrupted attempt...
    write(Data([0xff, 0xd8]), ddir.appendingPathComponent("0009.jpg"))                  // ...that left a stray page behind
    try await dl.download(se.id, chapter: ord[1])
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: ddir.path)) ?? []).filter { !$0.hasPrefix(".") }
    check(files.count == 3, "F8: a retried download holds exactly the chapter's pages (\(files.count))")
    try? FileManager.default.removeItem(at: Paths.downloads.appendingPathComponent(Paths.hash(se.id)))
    dl.deleteDownload(se.id, chapter: ord[1])
    let task = Task { try await dl.download(se.id, chapter: ord[3]) }
    task.cancel()
    _ = try? await task.value
    check(dl.entry(se.id)!.chapters.first { $0.chapter.url == ord[3] }!.downloaded == false
          && !FileManager.default.fileExists(atPath: Paths.downloads.appendingPathComponent(Paths.hash(se.id)).appendingPathComponent(Paths.hash(ord[3])).path),
          "F7: a cancelled download is not marked downloaded and leaves no files")
    try? FileManager.default.removeItem(at: safe)       // keep the local library as the later checks expect it
}

// ---------- engine lifecycle (pass --engine): needs Java and the already-downloaded engine jar, no network
@MainActor func engineLifecycle() async throws {
    let engine = ExtensionEngine.shared
    guard engine.isInstalled, ExtensionEngine.findJava() != nil else { print("SKIP  engine lifecycle (no jar or no Java)"); return }
    let tmpDir = Paths.root.appendingPathComponent("Engine/tmp")
    let stale = tmpDir.appendingPathComponent("tachidesk_network_cache999/x")
    write(Data(repeating: 1, count: 1000), stale)
    try await engine.ensureRunning()
    check(engine.state == .running && !FileManager.default.fileExists(atPath: stale.path), "E4: engine caches are wiped on engine start")
    let ps = Process(); ps.executableURL = URL(fileURLWithPath: "/bin/ps"); ps.arguments = ["-axo", "args"]
    let out = Pipe(); ps.standardOutput = out; try ps.run(); ps.waitUntilExit()
    let args = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let mine = args.split(separator: "\n").filter { $0.contains("user.home=\(Paths.home.path)") }
    check(mine.allSatisfy { $0.contains("globalUpdateInterval=0") && $0.contains("backupInterval=0") }, "E5: the engine's own update and backup jobs are off")
    check(!mine.isEmpty && !mine.contains { $0.contains("authPassword=") }, "S2: the engine password is not on any command line")
    // E3: kill Java; the next call must start a fresh engine instead of failing for good.
    run("/usr/bin/pkill", ["-f", "user.home=\(Paths.home.path)"])
    for _ in 0..<50 where engine.state == .running { try await Task.sleep(for: .milliseconds(100)) }
    check(engine.state == .stopped, "E3: when Java dies the state drops to stopped (\(engine.state))")
    try await engine.ensureRunning()
    check(engine.state == .running, "E3: the next call restarts the engine")
    let t0 = Date()
    engine.stop()
    check(Date().timeIntervalSince(t0) < 3 && engine.state == .stopped, "S6: stop() returns within 2-3 s")
}

do {
    if CommandLine.arguments.contains("--engine") {
        setvbuf(stdout, nil, _IOLBF, 0)
        try await engineLifecycle(); ExtensionEngine.shared.stop(); try? FileManager.default.removeItem(at: tmp)
        print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed."); exit(failures == 0 ? 0 : 1)
    }
    try await dataSafety()
    try await main()
    spreads()
    try await updates()
    try await migration()
    try await backups()
    try await readerSettings()
    try await sorting()
    try await savedVsHistory()
    try await network()
    if CommandLine.arguments.contains("--extensions") { try await extensions() }
    if let i = CommandLine.arguments.firstIndex(of: "--tmb"), i + 1 < CommandLine.arguments.count {
        // End-to-end on a real Tachimanga backup: convert, restore through the engine, import.
        let d = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        let proto = try TachimangaBackup.tachiyomiBackup(from: d)
        print("TMB converted:", proto.count, "bytes")
        let items = try await ExtensionEngine.shared.importTachimangaBackup(d) { a, b in if a % 20 == 0 { print("  restore", a, "/", b) } }
        let lib = Library(file: tmp.appendingPathComponent("tmb-real.json"))
        let r = lib.importSeries(items)
        let chapters = items.reduce(0) { $0 + $1.entry.chapters.count }, read = items.reduce(0) { $0 + $1.entry.chapters.filter(\.read).count }
        print("TMB items:", items.count, "added:", r.added, "chapters:", chapters, "read:", read, "withLastRead:", items.filter { $0.entry.lastRead != nil }.count)
        print("TMB sample:", items.prefix(3).map { "\($0.entry.series.title) [\($0.entry.chapters.count) ch, \($0.entry.series.sourceID)]" })
        check(items.count > 0 && read > 0, "tmb: a real Tachimanga backup imports with its read progress")
    }
    if CommandLine.arguments.contains("--schema") {
        let e = ExtensionEngine.shared
        for q in ["{ __schema { mutationType { fields { name args { name type { name kind ofType { name kind } } } } } } }"] {
            let d = try await e._queryForTesting(q)
            let f = (((d["__schema"] as? [String: Any])?["mutationType"] as? [String: Any])?["fields"] as? [[String: Any]]) ?? []
            for x in f where (x["name"] as? String ?? "").lowercased().contains("backup") { print("MUT", String(data: try JSONSerialization.data(withJSONObject: x, options: [.sortedKeys]), encoding: .utf8) ?? "") }
        }
        let qd = try await e._queryForTesting("{ __schema { queryType { fields { name } } } }")
        print("QUERIES", ((((qd["__schema"] as? [String: Any])?["queryType"] as? [String: Any])?["fields"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String })
        for t in ["RestoreBackupInput", "RestoreBackupPayload", "BackupRestoreStatus", "MangaType", "ChapterType", "MangaConditionInput", "MangaFilterInput", "CategoryType", "MangaNodeList"] {
            let d = try await e._queryForTesting("{ __type(name: \"\(t)\") { kind fields { name type { name kind ofType { name kind ofType { name } } } } inputFields { name type { name kind ofType { name } } } } }")
            if let o = d["__type"] as? [String: Any] { print("T", t, (((o["fields"] ?? o["inputFields"]) as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }) } else { print("T", t, "null") }
        }
    }
} catch { print("FAIL  unexpected error: \(error)"); failures += 1 }
ExtensionEngine.shared.stop()
try? FileManager.default.removeItem(at: tmp)
print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
