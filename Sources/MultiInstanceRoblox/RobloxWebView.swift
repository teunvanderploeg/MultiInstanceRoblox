import SwiftUI
import WebKit

struct RobloxWebView: NSViewRepresentable {
    @EnvironmentObject private var cache: RobloxWebViewCache

    let profile: RobloxProfile
    let requestedURL: URL?
    let onLaunchURL: (URL) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let webView = cache.webView(for: profile, onLaunchURL: onLaunchURL)
        if let requestedURL {
            cache.load(requestedURL, for: profile)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        _ = cache.webView(for: profile, onLaunchURL: onLaunchURL)
        if let requestedURL {
            cache.load(requestedURL, for: profile)
        }
    }
}
