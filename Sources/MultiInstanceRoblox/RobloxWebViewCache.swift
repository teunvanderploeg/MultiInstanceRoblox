import Foundation
import WebKit

@MainActor
final class BrowserState: ObservableObject {
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var pageTitle = "Roblox"
    @Published var errorMessage: String?
    var attemptedURL: URL?
    var failedURL: URL?

    func update(_ webView: WKWebView) {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
        pageTitle = webView.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Roblox"
    }
}

@MainActor
final class RobloxWebViewCache: ObservableObject {
    private let makeDataStore: (UUID) -> WKWebsiteDataStore
    private let makeWebView: (WKWebViewConfiguration) -> WKWebView

    init(homeURL: URL = URL(string: "https://www.roblox.com/")!, makeDataStore: @escaping (UUID) -> WKWebsiteDataStore = { WKWebsiteDataStore(forIdentifier: $0) },
         makeWebView: @escaping (WKWebViewConfiguration) -> WKWebView = { WKWebView(frame: .zero, configuration: $0) }) {
        self.homeURL = homeURL
        self.makeDataStore = makeDataStore
        self.makeWebView = makeWebView
    }

    private let homeURL: URL
    private var webViews: [UUID: WKWebView] = [:]
    private var delegates: [UUID: RobloxNavigationDelegate] = [:]
    private var states: [UUID: BrowserState] = [:]
    private var pendingURLs: [UUID: URL] = [:]

    func state(for profile: RobloxProfile) -> BrowserState {
        if let state = states[profile.id] { return state }
        let state = BrowserState()
        states[profile.id] = state
        return state
    }

    func webView(for profile: RobloxProfile, onLaunchURL: @escaping (URL) -> Void) -> WKWebView {
        if let webView = webViews[profile.id] {
            delegates[profile.id]?.onLaunchURL = onLaunchURL
            return webView
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = makeDataStore(profile.webDataStoreID)
        let delegate = RobloxNavigationDelegate(state: state(for: profile), onLaunchURL: onLaunchURL)
        let webView = makeWebView(configuration)
        webView.navigationDelegate = delegate
        webView.uiDelegate = delegate
        webView.allowsBackForwardNavigationGestures = true
        webViews[profile.id] = webView
        delegates[profile.id] = delegate
        webView.load(URLRequest(url: pendingURLs.removeValue(forKey: profile.id) ?? homeURL))
        return webView
    }

    /// Explicit user navigation is never deduplicated by URL.
    func navigate(_ url: URL, for profile: RobloxProfile) {
        let state = state(for: profile)
        state.errorMessage = nil
        state.failedURL = nil
        state.attemptedURL = url
        if let webView = webViews[profile.id] {
            webView.load(URLRequest(url: url))
        } else {
            pendingURLs[profile.id] = url
        }
    }

    func goBack(for profile: RobloxProfile) { webViews[profile.id]?.goBack() }
    func goForward(for profile: RobloxProfile) { webViews[profile.id]?.goForward() }
    func reload(for profile: RobloxProfile) {
        let state = state(for: profile)
        state.errorMessage = nil
        if let failedURL = state.failedURL {
            webViews[profile.id]?.load(URLRequest(url: failedURL))
        } else {
            webViews[profile.id]?.reload()
        }
    }
    func reloadHome(for profile: RobloxProfile) { navigate(homeURL, for: profile) }

    func removeWebView(for profile: RobloxProfile) {
        let webView = webViews.removeValue(forKey: profile.id)
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        delegates[profile.id] = nil
        states[profile.id] = nil
        pendingURLs[profile.id] = nil
    }
}

@MainActor
private final class RobloxNavigationDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    let state: BrowserState
    var onLaunchURL: (URL) -> Void

    init(state: BrowserState, onLaunchURL: @escaping (URL) -> Void) {
        self.state = state
        self.onLaunchURL = onLaunchURL
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .allow }
        if LaunchURL.isNative(url) {
            onLaunchURL(url)
            return .cancel
        }
        guard ["http", "https", "about"].contains(url.scheme?.lowercased() ?? "") else {
            state.errorMessage = "This link type is not supported. Open a Roblox game page or launch link."
            return .cancel
        }
        if action.targetFrame?.isMainFrame != false { state.attemptedURL = url }
        return .allow
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        state.errorMessage = nil
        state.update(webView)
        state.isLoading = true
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { state.update(webView) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        state.update(webView)
        state.isLoading = false
        state.failedURL = nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(webView, error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(webView, error) }
    private func failed(_ webView: WKWebView, _ error: Error) {
        state.update(webView)
        state.isLoading = false
        let failure = error as NSError
        if failure.domain != NSURLErrorDomain || failure.code != NSURLErrorCancelled {
            state.failedURL = failure.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? state.attemptedURL
            state.errorMessage = error.localizedDescription
        }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        state.isLoading = false
        state.errorMessage = "The browser stopped unexpectedly. Reload this page to continue."
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, let url = action.request.url {
            if LaunchURL.isNative(url) { onLaunchURL(url) }
            else if ["http", "https"].contains(url.scheme?.lowercased() ?? "") { webView.load(action.request) }
        }
        return nil
    }
}
