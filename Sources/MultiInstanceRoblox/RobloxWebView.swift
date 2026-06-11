import SwiftUI
import WebKit

struct RobloxWebView: NSViewRepresentable {
    @EnvironmentObject private var cache: RobloxWebViewCache

    let profile: RobloxProfile
    let requestedURL: URL?
    let onLaunchURL: (URL) -> Void

    func makeNSView(context: Context) -> WebViewHost {
        let host = WebViewHost()
        updateHost(host, context: context)
        return host
    }

    func updateNSView(_ host: WebViewHost, context: Context) {
        updateHost(host, context: context)
    }

    private func updateHost(_ host: WebViewHost, context: Context) {
        let webView = cache.webView(for: profile, requestedURL: requestedURL, onLaunchURL: onLaunchURL)
        host.setWebView(webView, profileID: profile.id)
    }
}

final class WebViewHost: NSView {
    private var currentProfileID: UUID?
    private weak var currentWebView: WKWebView?
    private var currentConstraints: [NSLayoutConstraint] = []

    override var isFlipped: Bool { true }

    func setWebView(_ webView: WKWebView, profileID: UUID) {
        guard currentProfileID != profileID || currentWebView !== webView else { return }

        NSLayoutConstraint.deactivate(currentConstraints)
        currentConstraints = []
        currentWebView?.removeFromSuperview()
        currentProfileID = profileID
        currentWebView = webView

        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        currentConstraints = [
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ]
        NSLayoutConstraint.activate(currentConstraints)
    }
}
