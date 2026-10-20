import SwiftUI
import WebKit

/// Plays the bundled SVG's own CSS timeline without scripts, network access, or user interaction.
struct SKIRRLogoAnimation: NSViewRepresentable {
    let svg: String
    func makeNSView(context: Context) -> LogoAnimationView { LogoAnimationView(svg: svg) }
    func updateNSView(_ nsView: LogoAnimationView, context: Context) {}
    static func dismantleNSView(_ nsView: LogoAnimationView, coordinator: ()) { nsView.stop() }
}

final class LogoAnimationView: NSView, WKNavigationDelegate {
    let webView: WKWebView
    private let svg: String
    private var started = false
    private var stopped = false

    init(svg: String) {
        self.svg = svg
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = NSColor(red: 11/255, green: 44/255, blue: 103/255, alpha: 1)
        webView.isHidden = true
        webView.allowsLinkPreview = false
        addSubview(webView)
    }

    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); webView.frame = bounds }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        guard let window else {
            if started { stop() }
            return
        }
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose),
                                              name: NSWindow.willCloseNotification, object: window)
        guard !started && !stopped else { return }
        started = true
        webView.loadHTMLString("""
        <!doctype html><html><head>
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#0b2c67}body>svg{display:block;width:100%;height:100%}</style>
        </head><body>\(svg)</body></html>
        """, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !stopped { webView.isHidden = false }
    }

    @objc private func windowWillClose() { stop() }
    func stop() {
        guard !stopped else { return }
        stopped = true
        NotificationCenter.default.removeObserver(self)
        webView.isHidden = true
        webView.navigationDelegate = nil
        webView.stopLoading()
        // Replacing the document discards its CSS animation timeline when settings close.
        webView.loadHTMLString("", baseURL: nil)
    }
}
