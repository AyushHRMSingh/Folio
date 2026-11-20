import AppKit
import Network
import SwiftUI
import WebKit

/// Folio's own answer to "this site is behind a Cloudflare check".
///
/// The extension engine can ask a FlareSolverr-style service for clearance. Folio runs that service itself on
/// 127.0.0.1, and instead of solving anything automatically it **asks the user**: a small "Verify you're human"
/// window opens on the blocked page, the user passes the check themselves, and the cookies plus Folio Web's user
/// agent go back to the engine, which then retries with them. Several blocked requests for the same site share one
/// window. Nothing is solved behind the user's back.
@MainActor
final class CloudflareSolver {
    static let shared = CloudflareSolver()
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    /// One verification per site at a time; everyone blocked on that site waits for the same answer.
    private var pending: [String: Task<Solution?, Never>] = [:]
    /// When cookies were last handed over without asking; asked again for the same site soon after means they
    /// didn't work, so the user is asked.
    private var lastSilent: [String: Date] = [:]

    struct Solution { let url: String; let cookies: [HTTPCookie]; let userAgent: String; let html: String }

    var url: String? { port == 0 ? nil : "http://127.0.0.1:\(port)/v1" }

    /// Starts listening (once). Returns when the port is known, so the engine can be launched with it.
    func start() async {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        guard let l = try? NWListener(using: params) else { return }
        listener = l
        l.newConnectionHandler = { c in Task { @MainActor in CloudflareSolver.shared.serve(c) } }
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            var resumed = false
            l.stateUpdateHandler = { st in
                Task { @MainActor in
                    if case .ready = st, !resumed { resumed = true; CloudflareSolver.shared.port = l.port?.rawValue ?? 0; k.resume() }
                    if case .failed = st, !resumed { resumed = true; k.resume() }
                }
            }
            l.start(queue: .main)
        }
    }

    // MARK: HTTP (just enough for FlareSolverr's JSON-over-POST)

    private func serve(_ c: NWConnection) {
        c.start(queue: .main)
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ buf: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, err in
            Task { @MainActor in
                var b = buf; if let data { b.append(data) }
                if let req = Self.request(from: b) {
                    let reply = await self.handle(req)
                    var out = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(reply.count)\r\nConnection: close\r\n\r\n".utf8)
                    out.append(reply)
                    c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
                } else if done || err != nil || b.count > 4 << 20 {
                    c.cancel()
                } else {
                    self.read(c, b)
                }
            }
        }
    }

    /// The JSON body once headers and the whole body (per Content-Length) have arrived.
    private static func request(from b: Data) -> [String: Any]? {
        guard let sep = b.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: b[..<sep.lowerBound], as: UTF8.self).lowercased()
        let len = head.split(separator: "\r\n").first { $0.hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        let body = b[sep.upperBound...]
        guard body.count >= len else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(body.prefix(len)))) as? [String: Any] ?? [:]
    }

    private func handle(_ req: [String: Any]) async -> Data {
        let started = Date()
        let cmd = req["cmd"] as? String ?? ""
        func reply(_ o: [String: Any]) -> Data {
            var r = o
            r["startTimestamp"] = Int(started.timeIntervalSince1970 * 1000)
            r["endTimestamp"] = Int(Date().timeIntervalSince1970 * 1000)
            r["version"] = "3.3.21"
            return (try? JSONSerialization.data(withJSONObject: r)) ?? Data("{}".utf8)
        }
        switch cmd {
        case "sessions.create": return reply(["status": "ok", "message": "Session created successfully.", "session": req["session"] as? String ?? "folio"])
        case "sessions.destroy": return reply(["status": "ok", "message": "The session has been removed."])
        case "sessions.list": return reply(["status": "ok", "message": "", "sessions": []])
        case "request.get", "request.post":
            guard let u = req["url"] as? String, let url = URL(string: u) else {
                return reply(["status": "error", "message": "Error: missing url"])
            }
            let timeout = (req["maxTimeout"] as? Double).map { $0 / 1000 } ?? 170
            guard let s = await solve(url, timeout: min(max(timeout - 5, 20), 600)) else {
                return reply(["status": "error", "message": "Error: The check wasn't completed in Folio's verify window."])
            }
            let cookies: [[String: Any]] = s.cookies.map { c in
                [
                    "name": c.name, "value": c.value, "domain": c.domain, "path": c.path,
                    "expires": c.expiresDate.map { $0.timeIntervalSince1970 } ?? -1,
                    "size": c.name.count + c.value.count, "httpOnly": c.isHTTPOnly, "secure": c.isSecure,
                    "session": c.expiresDate == nil, "sameSite": c.sameSitePolicy?.rawValue.capitalized ?? "None",
                ]
            }
            return reply(["status": "ok", "message": "Challenge solved!", "solution": [
                "url": s.url, "status": 200, "headers": [String: String](), "response": s.html,
                "cookies": cookies, "userAgent": s.userAgent,
            ]])
        default:
            return reply(["status": "error", "message": "Error: unknown command \(cmd)"])
        }
    }

    // MARK: deciding what to do

    /// Who is asking, if Folio knows: the source being read and its site (sent as the Referer, as the reader would).
    var context: (() -> (source: String, referer: URL?)?)?
    /// Called once per site when it hard-blocks Folio (nothing the user could pass).
    var onBlocked: ((String) -> Void)?
    /// Sites that hard-blocked recently. No window is shown for them until the pause runs out.
    private var blocked: [String: Date] = [:]
    private static let blockPause: TimeInterval = 15 * 60
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastBlockAt: Date?
    /// True while some site is hard-blocking Folio; reader tiles use it to say why pages fail.
    nonisolated static var recentlyBlocked: Bool {
        lock.lock(); defer { lock.unlock() }
        return lastBlockAt.map { Date().timeIntervalSince($0) < blockPause } ?? false
    }

    static func site(_ u: URL) -> String {
        let parts = (u.host ?? "").split(separator: ".")
        return parts.suffix(2).joined(separator: ".")          // cookies are per registrable domain
    }

    func solve(_ url: URL, timeout: TimeInterval) async -> Solution? {
        let site = Self.site(url)
        if let b = blocked[site], Date().timeIntervalSince(b) < Self.blockPause { return nil }
        if let t = pending[site] { return await t.value }
        let t = Task<Solution?, Never> { @MainActor in await self.run(url, site: site, timeout: timeout) }
        pending[site] = t
        let s = await t.value
        pending[site] = nil
        return s
    }

    /// Look first, out of sight. A hard block ends it, a page that simply loads is handed over, and only a real
    /// "are you human" check is shown to the user.
    private func run(_ url: URL, site: String, timeout: TimeInterval) async -> Solution? {
        let ctx = context?()
        let mainSite = ctx?.referer.map(Self.site)
        let who: String = {
            guard let src = ctx?.source else { return site }
            return mainSite == nil || mainSite == site ? "\(src) (\(site))" : "\(src)\u{2019}s image server (\(site))"
        }()
        let v = VerifyWindow(url: url, site: site, who: who, referer: ctx?.referer)
        switch await v.probe() {
        case .blocked:
            v.close(); markBlocked(site, who); return nil
        case .clear:
            // Loaded fine here. If the engine is back for the same site soon after, what we gave it didn't help.
            if let last = lastSilent[site], Date().timeIntervalSince(last) < 120 { v.close(); markBlocked(site, who); return nil }
            lastSilent[site] = Date()
            let s = await v.solution(); v.close(); return s
        case .challenge:
            let s = await v.askUser(timeout: timeout)
            if s == nil, v.sawBlock { markBlocked(site, who) }
            return s
        }
    }

    private func markBlocked(_ site: String, _ who: String) {
        blocked[site] = Date()
        Self.lock.lock(); Self.lastBlockAt = Date(); Self.lock.unlock()
        onBlocked?("\(who) is blocking Folio, so some pages or covers won\u{2019}t load. Try this series from another source.")
    }

    static func cookies(for site: String) async -> [HTTPCookie] {
        await WebStore.store.httpCookieStore.allCookies().filter { $0.domain.hasSuffix(site) }
    }
}

/// Loads the blocked address out of sight to see what it is, and shows it to the user only when it is a check
/// they can pass. Closes itself when they have.
@MainActor
final class VerifyWindow: NSObject, NSWindowDelegate, WKNavigationDelegate {
    enum Verdict { case clear, challenge, blocked }
    private let window: NSWindow
    private let web: WKWebView
    private var finished: ((CloudflareSolver.Solution?) -> Void)?
    private let url: URL
    private let site: String
    private let who: String
    private let referer: URL?
    private var before: String?
    private var loaded = false
    private(set) var sawBlock = false

    init(url: URL, site: String, who: String, referer: URL?) {
        self.url = url; self.site = site; self.who = who; self.referer = referer
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = WebStore.store
        web = WKWebView(frame: .zero, configuration: cfg)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        web.customUserAgent = WebStore.userAgent
        web.navigationDelegate = self
        window.title = "Verify \(who)"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    }

    /// Loads the page in an invisible window (so its scripts run normally) and waits to see what it is.
    func probe() async -> Verdict {
        before = await CloudflareSolver.cookies(for: site).first { $0.name == "cf_clearance" }?.value
        let header = NSHostingView(rootView: VerifyHeader(who: who, cancel: { [weak self] in self?.finish(nil) }))
        let stack = NSStackView(views: [header, web])
        stack.orientation = .vertical; stack.spacing = 0
        header.setContentHuggingPriority(.required, for: .vertical)
        window.contentView = stack
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.center()
        window.orderFrontRegardless()
        var req = URLRequest(url: url)
        if let r = referer { req.setValue(r.absoluteString, forHTTPHeaderField: "Referer") }
        web.load(req)
        // Up to 20 s to load; a self-solving check gets up to 8 s more to finish on its own.
        let deadline = Date().addingTimeInterval(20)
        var challengeSince: Date?
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(400))
            guard loaded else { continue }
            switch await classify() {
            case .blocked: sawBlock = true; return .blocked
            case .clear: return .clear
            case .challenge:
                if challengeSince == nil { challengeSince = Date() }
                if Date().timeIntervalSince(challengeSince!) > 8 { return .challenge }
            }
        }
        return loaded ? .challenge : .blocked
    }

    private static let classifyJS = """
    (() => {
      const t = (document.title || '').toLowerCase();
      const b = ((document.body && document.body.innerText) || '').toLowerCase().slice(0, 4000);
      const q = s => document.querySelector(s) != null;
      if (b.includes('you have been blocked') || b.includes('error 1020') || b.includes('error 1010') || b.includes('error 1015')
          || (b.includes('access denied') && b.includes('cloudflare')) || (q('#cf-error-details') && !q('#challenge-form'))) return 'blocked';
      if (t.includes('just a moment') || t.includes('checking your browser') || q('#challenge-form') || q('#challenge-stage')
          || q('.cf-turnstile') || q('iframe[src*="challenges.cloudflare.com"]')) return 'challenge';
      return 'clear';
    })()
    """

    private func classify() async -> Verdict {
        switch (try? await web.evaluateJavaScript(Self.classifyJS)) as? String {
        case "blocked": return .blocked
        case "challenge": return .challenge
        default: return .clear
        }
    }

    func solution() async -> CloudflareSolver.Solution {
        let html = (try? await web.evaluateJavaScript("document.documentElement.outerHTML") as? String) ?? ""
        return CloudflareSolver.Solution(url: web.url?.absoluteString ?? url.absoluteString,
                                         cookies: await CloudflareSolver.cookies(for: site),
                                         userAgent: WebStore.userAgent, html: html)
    }

    /// Shows the check (already loaded) and waits until it's passed, cancelled, turns into a block, or times out.
    func askUser(timeout: TimeInterval) async -> CloudflareSolver.Solution? {
        await withCheckedContinuation { k in
            finished = { k.resume(returning: $0) }
            window.alphaValue = 1
            window.ignoresMouseEvents = false
            window.level = .floating
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            Task {
                let deadline = Date().addingTimeInterval(timeout)
                while finished != nil, Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(700))
                    switch await classify() {
                    case .blocked: sawBlock = true; finish(nil); return
                    case .clear: if await freshClearance() { finish(await solution()); return }
                    case .challenge: break
                    }
                }
                finish(nil)
            }
        }
    }

    private func freshClearance() async -> Bool {
        guard let c = await CloudflareSolver.cookies(for: site).first(where: { $0.name == "cf_clearance" }) else { return false }
        return c.value != before
    }

    func close() { window.delegate = nil; web.stopLoading(); window.orderOut(nil) }

    private func finish(_ s: CloudflareSolver.Solution?) {
        guard let f = finished else { return }
        finished = nil
        close()
        f(s)
    }

    func windowWillClose(_ notification: Notification) { finish(nil) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loaded = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { loaded = true }
}

private struct VerifyHeader: View {
    let who: String
    let cancel: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.shield").font(.system(size: 18)).foregroundStyle(Theme.ink)
            VStack(alignment: .leading, spacing: 3) {
                Text("Verify you\u{2019}re human").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                Text("\(who) wants a check before Folio can load it. Complete it below. This window closes when you pass.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Cancel", action: cancel).buttonStyle(.mono)
        }
        .padding(.horizontal, 14).padding(.vertical, 16)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.bg)
    }
}
