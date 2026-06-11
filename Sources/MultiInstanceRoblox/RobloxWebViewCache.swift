import Foundation
import WebKit

@MainActor
final class RobloxWebViewCache: ObservableObject {
    private let homeURL = URL(string: "https://www.roblox.com/")!
    private var webViews: [UUID: WKWebView] = [:]
    private var delegates: [UUID: RobloxNavigationDelegate] = [:]
    private var lastRequestedURLs: [UUID: URL] = [:]

    func webView(for profile: RobloxProfile, requestedURL: URL? = nil, onLaunchURL: @escaping (URL) -> Void) -> WKWebView {
        if let webView = webViews[profile.id] {
            delegates[profile.id]?.onLaunchURL = onLaunchURL
            if let requestedURL {
                load(requestedURL, for: profile)
            }
            return webView
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: profile.webDataStoreID)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let delegate = RobloxNavigationDelegate(onLaunchURL: onLaunchURL)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = delegate
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Apple Silicon Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

        webViews[profile.id] = webView
        delegates[profile.id] = delegate
        let initialURL = requestedURL ?? homeURL
        lastRequestedURLs[profile.id] = initialURL
        webView.load(URLRequest(url: initialURL))
        return webView
    }

    func load(_ url: URL, for profile: RobloxProfile) {
        guard lastRequestedURLs[profile.id] != url else { return }
        guard let webView = webViews[profile.id] else { return }
        lastRequestedURLs[profile.id] = url
        webView.load(URLRequest(url: url))
    }

    func reloadHome(for profile: RobloxProfile) {
        lastRequestedURLs[profile.id] = homeURL
        webViews[profile.id]?.load(URLRequest(url: homeURL))
    }

    func removeWebView(for profile: RobloxProfile) {
        webViews[profile.id]?.stopLoading()
        webViews[profile.id]?.navigationDelegate = nil
        webViews[profile.id] = nil
        delegates[profile.id] = nil
        lastRequestedURLs[profile.id] = nil
    }
}

private final class RobloxNavigationDelegate: NSObject, WKNavigationDelegate {
    var onLaunchURL: (URL) -> Void

    init(onLaunchURL: @escaping (URL) -> Void) {
        self.onLaunchURL = onLaunchURL
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else {
            return .allow
        }

        if url.scheme == "roblox" || url.scheme == "roblox-player" {
            onLaunchURL(url)
            return .cancel
        }

        return .allow
    }
}
