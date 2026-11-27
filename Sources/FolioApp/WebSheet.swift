import AppKit
import SwiftUI
import WebKit

// MARK: - Folio's web view
// A real (small) browser for the source's own pages, shown as a page inside Folio's window (`AppModel.web`), with a
// persistent, Folio-only website data store, so logins and Cloudflare checks you pass survive but never touch Safari.

enum WebStore {
    /// Fixed identifier of Folio's website data store (macOS 14+). Never change it, or saved logins are orphaned.
    static let identifier = UUID(uuidString: "F0110C0D-7EB5-4A11-9B0A-0F0110F0110F")!
    static let store = WKWebsiteDataStore(forIdentifier: identifier)

    /// Desktop Safari-like user agent. Many sites (and Cloudflare) treat the default WKWebView agent oddly.
    /// NOTE: this should later be matched to the extension engine's user agent, because a Cloudflare clearance
    /// cookie is only honoured for the UA that earned it.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

    /// Removes everything the web view has stored: cookies, caches, local storage, IndexedDB.
    static func clear() async {
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
}

@MainActor
final class WebState: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published var url: URL?
    @Published var pageTitle = ""
    @Published var loading = false
    @Published var progress = 0.0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var failure: String?
    let view: WKWebView
    private var observers: [NSKeyValueObservation] = []
    private var lastRequested: URL?

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = WebStore.store
        view = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        view.customUserAgent = WebStore.userAgent
        view.allowsBackForwardNavigationGestures = true
        view.navigationDelegate = self
        view.uiDelegate = self
        observers = [
            view.observe(\.url, options: [.new]) { [weak self] v, _ in MainActor.assumeIsolated { self?.url = v.url } },
            view.observe(\.title, options: [.new]) { [weak self] v, _ in MainActor.assumeIsolated { self?.pageTitle = v.title ?? "" } },
            view.observe(\.isLoading, options: [.new]) { [weak self] v, _ in MainActor.assumeIsolated { self?.loading = v.isLoading } },
            view.observe(\.estimatedProgress, options: [.new]) { [weak self] v, _ in MainActor.assumeIsolated { self?.progress = v.estimatedProgress } },
            view.observe(\.canGoBack, options: [.new]) { [weak self] v, _ in MainActor.assumeIsolated { self?.canGoBack = v.canGoBack } },
            view.observe(\.canGoForward, options: [.new]) { [weak self] v, _ in MainActor.assumeIsolated { self?.canGoForward = v.canGoForward } },
        ]
    }

    func shutdown() { observers.removeAll(); view.stopLoading(); view.navigationDelegate = nil; view.uiDelegate = nil }

    func load(_ u: URL) { failure = nil; lastRequested = u; view.load(URLRequest(url: u)) }
    func retry() { if let u = view.url ?? lastRequested { load(u) } }
    func reloadOrStop() { if loading { view.stopLoading() } else if failure != nil { retry() } else { view.reload() } }

    /// Address-field input → URL. Full URLs as typed; plain words become https://word; phrases search the web.
    static func normalize(_ raw: String) -> URL? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t.contains("://") { return URL(string: t) }
        if t.contains(" ") {
            var c = URLComponents(string: "https://duckduckgo.com/")!
            c.queryItems = [URLQueryItem(name: "q", value: t)]
            return c.url
        }
        return URL(string: "https://" + t)
    }

    // MARK: Navigation delegate
    func webView(_ w: WKWebView, didStartProvisionalNavigation n: WKNavigation!) { failure = nil }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { fail(e) }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { fail(e) }
    private func fail(_ e: Error) {
        let ns = e as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }      // "Frame load interrupted": a download we declined
        failure = ns.localizedDescription
    }
    /// Downloads are ignored gracefully: anything WebKit can't display (a file) is cancelled, not saved.
    func webView(_ w: WKWebView, decidePolicyFor r: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        r.canShowMIMEType ? .allow : .cancel
    }
    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction) async -> WKNavigationActionPolicy {
        a.shouldPerformDownload ? .cancel : .allow
    }
    // target=_blank / window.open: same view, no extra windows.
    func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures f: WKWindowFeatures) -> WKWebView? {
        if let u = a.request.url { w.load(URLRequest(url: u)) }
        return nil
    }
}

struct WebBrowserView: View {
    @ObservedObject var state: WebState
    let close: () -> Void
    @State private var address = ""
    @State private var shownAddress = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ZStack(alignment: .top) {
                Rectangle().fill(Theme.line).frame(height: 1)
                GeometryReader { g in
                    Rectangle().fill(Theme.ink).frame(width: g.size.width * state.progress, height: 1.5)
                        .opacity(state.loading ? 1 : 0).animation(.easeOut(duration: 0.15), value: state.progress)
                }.frame(height: 1.5)
            }.frame(height: 1.5)
            ZStack {
                WebHost(view: state.view)
                if let f = state.failure {
                    VStack(spacing: 12) {
                        Text("This page didn\u{2019}t load").font(.folioSection).foregroundStyle(Theme.ink)
                        Text(f).font(.folioMeta).foregroundStyle(Theme.dim).multilineTextAlignment(.center).frame(maxWidth: 420)
                        TextAction(title: "Retry") { state.retry() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
                }
            }
        }
        .background(Theme.bg)
        .background(shortcuts)
        // Follow the page's address unless the user is typing something of their own.
        .onChange(of: state.url) { _, u in
            let new = u?.absoluteString ?? ""
            if !addressFocused || address.isEmpty || address == shownAddress { address = new }
            shownAddress = new
        }
        .onChange(of: addressFocused) { _, f in if !f { address = state.url?.absoluteString ?? "" } }
        .onAppear { address = state.url?.absoluteString ?? ""; shownAddress = address }    // loading may start before the page shows
    }

    var toolbar: some View {
        HStack(spacing: 4) {
            Button(action: close) {
                HStack(spacing: 5) { Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)); Text("Back") }
                    .font(.system(size: 14)).foregroundStyle(Theme.ink).padding(.horizontal, 9).padding(.vertical, 5).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Back to Folio (Esc)")
            Rectangle().fill(Theme.line).frame(width: 1, height: 18).padding(.horizontal, 6)
            TextAction(title: "←", disabled: !state.canGoBack) { state.view.goBack() }
            TextAction(title: "→", disabled: !state.canGoForward) { state.view.goForward() }
            TextAction(title: state.loading ? "Stop" : "Reload") { state.reloadOrStop() }
            TextField("Address", text: $address)
                .textFieldStyle(.plain).font(.folioMono).foregroundStyle(Theme.ink)
                .focused($addressFocused).autocorrectionDisabled()
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                .onSubmit { if let u = WebState.normalize(address) { state.load(u) }; addressFocused = false }
            TextAction(title: "Copy link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(state.url?.absoluteString ?? address, forType: .string)
            }
            TextAction(title: "Open in browser", disabled: state.url == nil) { if let u = state.url { NSWorkspace.shared.open(u) } }
        }
        // Clear of the window's traffic lights: the title bar is transparent and the page runs under it.
        .padding(.leading, 78).padding(.trailing, 12).padding(.top, 8).padding(.bottom, 10)
    }

    /// Hidden buttons carry the keyboard shortcuts.
    var shortcuts: some View {
        ZStack {
            Button("") { state.view.goBack() }.keyboardShortcut("[", modifiers: .command)
            Button("") { state.view.goForward() }.keyboardShortcut("]", modifiers: .command)
            Button("") { state.reloadOrStop() }.keyboardShortcut("r", modifiers: .command)
            Button("") { addressFocused = true }.keyboardShortcut("l", modifiers: .command)
            Button("") { close() }.keyboardShortcut(.cancelAction)
        }
        .opacity(0).allowsHitTesting(false)
    }
}

struct WebHost: NSViewRepresentable {
    let view: WKWebView
    func makeNSView(context: Context) -> WKWebView {
        // Keys go to the page, not to the reader left open underneath (Space would scroll it).
        DispatchQueue.main.async { [view] in view.window?.makeFirstResponder(view) }
        return view
    }
    func updateNSView(_ v: WKWebView, context: Context) {}
}
