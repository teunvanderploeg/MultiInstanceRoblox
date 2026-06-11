import SwiftUI

@main
struct MultiInstanceRobloxApp: App {
    @StateObject private var profileStore = ProfileStore()
    @StateObject private var launcher = RobloxLauncher()
    @StateObject private var webViewCache = RobloxWebViewCache()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(profileStore)
                .environmentObject(launcher)
                .environmentObject(webViewCache)
                .frame(minWidth: 1180, minHeight: 720)
        }
        .windowStyle(.titleBar)
    }
}
