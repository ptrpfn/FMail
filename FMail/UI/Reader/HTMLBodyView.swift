import AppKit
import SwiftUI
import WebKit

/// Renders HTML email bodies in a locked-down WKWebView.
///
/// Hard rules to preserve FMail's "zero network" promise:
///   • Content-Security-Policy blocks all external resources — no remote
///     image fetching (the classic email read-tracking pixel), no fonts, no
///     scripts, no iframes.
///   • `allowsContentJavaScript = false` so any `<script>` in the message
///     does nothing.
///   • Link clicks (`linkActivated`) are handed off to the default browser
///     via `NSWorkspace`; they don't navigate the web view.
///
/// External `evaluateJavaScript` from FMail still works, which we use to
/// measure rendered height for SwiftUI sizing.
struct HTMLBodyView: NSViewRepresentable {
    let html: String
    let allowRemoteImages: Bool
    @Binding var measuredHeight: CGFloat

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = PassThroughScrollWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")  // Transparent — pick up parent's background
        webView.allowsLinkPreview = false
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Guard against a feedback loop: SwiftUI calls updateNSView every time
        // the View struct changes, which includes when measuredHeight (a
        // @Binding we write to from didFinish) updates. Without this check we
        // re-load the HTML every time the height shifts a pixel — for HTML
        // with external images, image-load timing causes height to drift,
        // so the loop never settles. Only reload on real content changes.
        if context.coordinator.lastLoadedHTML == html
            && context.coordinator.lastLoadedAllowRemote == allowRemoteImages {
            return
        }
        context.coordinator.lastLoadedHTML = html
        context.coordinator.lastLoadedAllowRemote = allowRemoteImages
        let wrapped = Self.wrap(html: html, allowRemoteImages: allowRemoteImages)
        webView.loadHTMLString(wrapped, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(measuredHeight: $measuredHeight)
    }

    /// Heuristic: does the HTML contain any external `<img>` source we'd
    /// otherwise block? Used to decide whether to show the "Load remote
    /// images" button. Cheap substring scan — no real HTML parsing.
    static func containsRemoteImages(_ html: String) -> Bool {
        let lower = html.lowercased()
        return lower.contains("src=\"http")
            || lower.contains("src='http")
            || lower.contains("src=http")
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var measuredHeight: CGFloat
        var lastLoadedHTML: String?
        var lastLoadedAllowRemote: Bool?

        init(measuredHeight: Binding<CGFloat>) {
            self._measuredHeight = measuredHeight
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            measureHeight(webView)
            // Re-measure after a beat — gives external images time to load
            // and reflow the document so we don't clip them.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak webView] in
                guard let webView else { return }
                self?.measureHeight(webView)
            }
        }

        private func measureHeight(_ webView: WKWebView) {
            webView.evaluateJavaScript("document.documentElement.scrollHeight") { [weak self] result, _ in
                let height: CGFloat
                if let n = result as? NSNumber { height = CGFloat(truncating: n) }
                else if let d = result as? Double { height = CGFloat(d) }
                else if let i = result as? Int { height = CGFloat(i) }
                else { return }
                guard let self else { return }
                let target = max(80, height + 8)
                if abs(self.measuredHeight - target) > 1 {
                    self.measuredHeight = target
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            switch navigationAction.navigationType {
            case .linkActivated, .formSubmitted, .formResubmitted:
                if let url = navigationAction.request.url, url.scheme == "http" || url.scheme == "https" || url.scheme == "mailto" {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
            case .other, .reload:
                // The initial loadHTMLString comes through as `.other`. Allow it.
                decisionHandler(.allow)
            case .backForward:
                decisionHandler(.cancel)
            @unknown default:
                decisionHandler(.cancel)
            }
        }
    }

    /// `WKWebView` subclass that hands scroll events up to its parent.
    /// We size the web view to fit its content (via `evaluateJavaScript`),
    /// so its internal `NSScrollView` never has anything to scroll. Without
    /// this override the internal scroller still eats wheel/trackpad events,
    /// causing a brief jiggle but no visible scroll — and the user has to
    /// move the cursor outside the WebView's bounds to scroll the message.
    /// Forwarding the events makes the outer `ScrollView` handle them.
    private final class PassThroughScrollWebView: WKWebView {
        override func scrollWheel(with event: NSEvent) {
            nextResponder?.scrollWheel(with: event)
        }
    }

    private static func wrap(html: String, allowRemoteImages: Bool) -> String {
        // The CSP is the load-bearing line. `default-src 'none'` blocks
        // everything by default; we then explicitly allow inline styles and
        // data:/cid: URIs (cid: is for inline-attached images that Mail.app
        // already cached locally; we don't synthesise the resolution today
        // but the policy is forward-compatible).
        // When `allowRemoteImages` is true, we additionally allow http/https
        // image sources — opt-in only, used by the "Load remote images"
        // button per message. Scripts/fonts/iframes stay blocked even then.
        let imgSrc = allowRemoteImages
            ? "img-src data: cid: http: https:"
            : "img-src data: cid:"
        let csp = "default-src 'none'; \(imgSrc); style-src 'unsafe-inline'; font-src data:;"
        let css = """
        :root { color-scheme: light dark; }
        html, body { margin: 0; padding: 0; }
        body {
            font: -apple-system-body;
            font-size: 14px;
            line-height: 1.4;
            padding: 4px 0 0 0;
            color: canvastext;
            background: transparent;
            word-wrap: break-word;
            overflow-wrap: anywhere;
        }
        a { color: link; }
        img { max-width: 100%; height: auto; }
        pre, code { font-family: ui-monospace, monospace; font-size: 13px; }
        pre { white-space: pre-wrap; word-break: break-word; }
        blockquote {
            border-left: 3px solid currentColor;
            padding-left: 12px;
            opacity: 0.6;
            margin: 8px 0 8px 0;
        }
        table { border-collapse: collapse; max-width: 100%; }
        td, th { padding: 4px 8px; vertical-align: top; }
        ul, ol { padding-left: 24px; }
        """
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="\(csp)">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>\(css)</style>
        </head>
        <body>\(html)</body>
        </html>
        """
    }
}
