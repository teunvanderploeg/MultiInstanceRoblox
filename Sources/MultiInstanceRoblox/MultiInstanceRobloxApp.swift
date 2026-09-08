import SwiftUI

@main
struct MultiInstanceRobloxApp: App {
    @StateObject private var profileStore: ProfileStore
    @StateObject private var launcher = RobloxLauncher()
    @StateObject private var webViewCache: RobloxWebViewCache

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("MultiInstanceRobloxPreview-\(UUID())")
            let store = ProfileStore(rootDirectory: root)
            store.addProfile(named: "Second account")
            store.selectedProfileID = store.profiles.first?.id
            _profileStore = StateObject(wrappedValue: store)
            _webViewCache = StateObject(wrappedValue: RobloxWebViewCache(
                homeURL: URL(string: "about:blank")!, makeDataStore: { _ in .nonPersistent() }))
            return
        }
        #endif
        _profileStore = StateObject(wrappedValue: ProfileStore())
        _webViewCache = StateObject(wrappedValue: RobloxWebViewCache())
    }

    var body: some Scene {
        Window("MultiInstanceRoblox", id: "main") {
            ContentView()
                .environmentObject(profileStore)
                .environmentObject(launcher)
                .environmentObject(webViewCache)
                .frame(minWidth: 980, minHeight: 720)
        }
        .windowStyle(.titleBar)
    }
}
