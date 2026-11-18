import SwiftUI
import WebKit

/// Data browsing is served by the local archive worker. Its read-only API owns
/// search and source inspection; the dictation coordinator keeps inference separate.
struct TranscriptDataPage: View {
    private let url = URL(string: "http://127.0.0.1:8392")!
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Shared transcript archive").font(.headline)
                Spacer()
                Link("Open in browser", destination: url)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            TranscriptArchiveWebView(url: url)
        }
        .accessibilityIdentifier("data.archive")
    }
}

private struct TranscriptArchiveWebView: NSViewRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        /// The NAS transcripts viewer is the only outside address the Data tab may open.
        /// It opens in the default browser, never inside this WebView.
        private static let nasViewerAddresses: Set<String> = [
            "https://transcripts.lascari.dev",
            "https://transcripts.lascari.dev/",
        ]

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.request.url?.absoluteString == "about:blank" {
                decisionHandler(.allow)
                return
            }
            if let url = action.request.url,
               Self.nasViewerAddresses.contains(url.absoluteString) {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            guard let url = action.request.url,
                  url.scheme == "http", url.host == "127.0.0.1", url.port == 8392 else {
                decisionHandler(.cancel)
                return
            }
            if action.targetFrame == nil {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else { decisionHandler(.allow) }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            // A failed archive service must be visible, rather than an empty data page.
            webView.loadHTMLString("""
            <html><body style="font:16px -apple-system;padding:40px;color:#34483b;background:#f7f7f2">
            <h2>The transcript archive is offline</h2>
            <p>Open Start Transcriber.command to start the archive service, then return to Data.</p>
            <p><a href="http://127.0.0.1:8392">Try again</a></p>
            </body></html>
            """, baseURL: URL(string: "http://127.0.0.1:8392"))
        }
    }
}
