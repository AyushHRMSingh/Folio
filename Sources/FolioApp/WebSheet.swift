import AppKit
import SwiftUI
import WebKit

/// The source's own page for a series or chapter, in the app. Nothing is kept: cookies and caches live
/// only as long as the sheet.
struct WebSheet: View {
    let target: WebTarget
    let close: () -> Void
    @StateObject private var state = WebState()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text(target.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(state.host).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.faint).lineLimit(1)
                if state.loading { ProgressView().controlSize(.small) }
                Spacer()
                TextAction(title: "←", disabled: !state.canGoBack) { state.view?.goBack() }
                TextAction(title: "reload") { state.view?.reload() }
                TextAction(title: "open in browser") { NSWorkspace.shared.open(state.view?.url ?? target.url) }
                TextAction(title: "close", action: close)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Rectangle().fill(Theme.line).frame(height: 1)
            WebHost(url: target.url, state: state)
        }
        .frame(minWidth: 960, minHeight: 680)
        .background(Theme.bg)
    }
}

@MainActor
final class WebState: ObservableObject {
    @Published var host = ""
    @Published var loading = true
    @Published var canGoBack = false
    var view: WKWebView?
}

struct WebHost: NSViewRepresentable {
    let url: URL
    let state: WebState

    func makeCoordinator() -> Coordinator { Coordinator(state) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()          // leaves nothing on disk
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.navigationDelegate = context.coordinator
        v.allowsBackForwardNavigationGestures = true
        state.view = v
        v.load(URLRequest(url: url))
        return v
    }
    func updateNSView(_ v: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let state: WebState
        init(_ s: WebState) { state = s }
        func webView(_ w: WKWebView, didStartProvisionalNavigation n: WKNavigation!) { state.loading = true }
        func webView(_ w: WKWebView, didFinish n: WKNavigation!) { sync(w) }
        func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { sync(w) }
        func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { sync(w) }
        private func sync(_ w: WKWebView) {
            state.loading = false; state.host = w.url?.host ?? ""; state.canGoBack = w.canGoBack
        }
    }
}
