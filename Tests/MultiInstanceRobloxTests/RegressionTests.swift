import Foundation
import Testing
import WebKit
@testable import MultiInstanceRoblox

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("MultiInstanceRobloxTests-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite @MainActor
struct ProfileRecoveryTests {
    @Test func corruptedFileSurvivesInitializationAndEdits() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("profiles.json")
        let damaged = Data("unreadable profiles".utf8)
        try damaged.write(to: file)
        let store = ProfileStore(rootDirectory: root)
        store.addProfile()
        #expect(store.needsRecovery)
        #expect(store.profiles.isEmpty)
        #expect(try Data(contentsOf: file) == damaged)
    }

    @Test func backupRestoresAndPreservesDamagedOriginal() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = ProfileStore(rootDirectory: root)
        let main = try #require(initial.profiles.first)
        initial.addProfile(named: "Second")
        let file = root.appendingPathComponent("profiles.json")
        let damaged = Data("bad json".utf8)
        try damaged.write(to: file)
        let recovered = ProfileStore(rootDirectory: root)
        #expect(recovered.canRestoreBackup)
        recovered.recoverFromBackup()
        #expect(!recovered.needsRecovery)
        #expect(recovered.profiles.map(\.id) == [main.id])
        let preserved = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("profiles.unreadable-") }
        #expect(preserved.count == 1)
        #expect(try Data(contentsOf: #require(preserved.first)) == damaged)
        #expect(ProfileStore(rootDirectory: root).profiles.map(\.id) == [main.id])
    }

    @Test func startFreshKeepsOriginalFile() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("profiles.json")
        try Data("broken".utf8).write(to: file)
        let store = ProfileStore(rootDirectory: root)
        store.startFreshAfterRecovery()
        #expect(!store.needsRecovery)
        #expect(store.profiles.count == 1)
        #expect(ProfileStore(rootDirectory: root).profiles.count == 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(files.contains { $0.hasPrefix("profiles.unreadable-") })
    }

    @Test func cloneCompletionPreservesEditsMadeDuringBuild() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(rootDirectory: root)
        let snapshot = try #require(store.profiles.first)
        store.setNotes(id: snapshot.id, notes: "Edited while preparing")
        store.markCloneUpdated(for: snapshot, sourceVersion: "new-version")
        #expect(store.profiles.first?.notes == "Edited while preparing")
        #expect(store.profiles.first?.lastSourceVersion == "new-version")
    }

    @Test func deletingLastProfileStaysEmptyAfterRestart() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(rootDirectory: root)
        store.deleteMetadata(id: try #require(store.profiles.first).id)
        #expect(ProfileStore(rootDirectory: root).profiles.isEmpty)
    }

    @Test func failedMetadataDeletionKeepsProfileForRetry() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(rootDirectory: root)
        let id = try #require(store.profiles.first).id
        // An unreadable on-disk file must not be overwritten by deletion.
        try Data("broken".utf8).write(to: root.appendingPathComponent("profiles.json"))
        store.deleteMetadata(id: id)
        #expect(store.profiles.first?.id == id)
        #expect(store.errorMessage != nil)
    }
}

@Suite
struct CloneRepairTests {
    @Test func validationFailurePreservesWorkingCopy() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source.app")
        let clone = root.appendingPathComponent("Clone.app")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: source.appendingPathComponent("version"))
        try Data("working".utf8).write(to: clone.appendingPathComponent("version"))
        #expect(throws: WorkerError.self) {
            try RobloxWorker.install(source: source, destination: clone) { _ in throw WorkerError.command("Signing failed") }
        }
        #expect(try String(contentsOf: clone.appendingPathComponent("version"), encoding: .utf8) == "working")
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(files.sorted() == ["Clone.app", "Source.app"])
    }

    @Test func successfulReplacementUsesVerifiedCopy() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source.app")
        let clone = root.appendingPathComponent("Clone.app")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: clone.appendingPathComponent("old"))
        try RobloxWorker.install(source: source, destination: clone) { staging in
            #expect(FileManager.default.fileExists(atPath: clone.appendingPathComponent("old").path))
            try Data("verified".utf8).write(to: staging.appendingPathComponent("new"))
        }
        #expect(try String(contentsOf: clone.appendingPathComponent("new"), encoding: .utf8) == "verified")
        #expect(!FileManager.default.fileExists(atPath: clone.appendingPathComponent("old").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2)
    }

    @Test func replacementMoveFailureRollsBack() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source.app")
        let clone = root.appendingPathComponent("Clone.app")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
        try Data("working".utf8).write(to: clone.appendingPathComponent("version"))
        #expect(throws: (any Error).self) {
            try RobloxWorker.install(source: source, destination: clone) { staging in
                try FileManager.default.removeItem(at: staging)
            }
        }
        #expect(try String(contentsOf: clone.appendingPathComponent("version"), encoding: .utf8) == "working")
    }

    @Test func sourceVersionRefreshReadsUpdatedPlist() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        for version in ["1", "2"] {
            let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleVersion": version], format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
            #expect(RobloxWorker.version(at: root) == version)
        }
    }
}

@Suite
struct LaunchTests {
    @Test func runningProfileNeverTriggersRepair() {
        #expect(LaunchAction.forStatus(.running) == .reuse)
        #expect(LaunchAction.forStatus(.ready) == .open)
        #expect(LaunchAction.forStatus(.missingClone) == .prepare)
        #expect(LaunchAction.forStatus(.staleClone(sourceVersion: "2", cloneVersion: "1")) == .prepare)
        #expect(LaunchAction.forStatus(.error("broken")) == .prepare)
    }

    @Test func matchingVersionWithBrokenExecutableNeedsRepair() {
        var profile = RobloxProfile(name: "Test", colorName: "blue", rootDirectory: URL(fileURLWithPath: "/tmp"))
        profile.lastSourceVersion = "2"
        let health = CloneHealth(sourceVersion: "2", cloneVersion: "2", bundleIdentifier: "test", isSigned: true, executableExists: false)
        #expect(RobloxLauncher.diskStatus(profile: profile, health: health).needsRepair)
    }

    @Test func searchTextDoesNotBecomeExtraQueryParameters() throws {
        let url = try #require(LaunchURL.parse("cats & dogs #one"))
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query == [URLQueryItem(name: "keyword", value: "cats & dogs #one")])
        #expect(LaunchURL.parse("javascript:alert(1)") == nil)
        #expect(LaunchURL.parse("file:///etc/passwd") == nil)
        #expect(LaunchURL.isNative(try #require(URL(string: "ROBLOX:launch"))))
    }
}

@MainActor
private final class RecordingWebView: WKWebView {
    var requests: [URLRequest] = []
    override func load(_ request: URLRequest) -> WKNavigation? {
        requests.append(request)
        return nil
    }
}

@Suite @MainActor
struct BrowserTests {
    private func cache() -> RobloxWebViewCache {
        RobloxWebViewCache(makeDataStore: { _ in .nonPersistent() }, makeWebView: { configuration in
            RecordingWebView(frame: .zero, configuration: configuration)
        })
    }

    @Test func repeatedOpenNavigatesAgainWithoutViewUpdateReloads() throws {
        let cache = cache()
        let profile = RobloxProfile(name: "Test", colorName: "blue", rootDirectory: URL(fileURLWithPath: "/tmp"))
        let webView = try #require(cache.webView(for: profile) { _ in } as? RecordingWebView)
        let url = try #require(URL(string: "https://www.roblox.com/games/123"))
        cache.navigate(url, for: profile)
        cache.navigate(url, for: profile)
        #expect(webView.requests.map(\.url) == [URL(string: "https://www.roblox.com/"), url, url])
        _ = cache.webView(for: profile) { _ in }
        #expect(webView.requests.count == 3)
    }

    @Test func retryLoadsFailedDestinationRatherThanPreviousPage() throws {
        let cache = cache()
        let profile = RobloxProfile(name: "Test", colorName: "blue", rootDirectory: URL(fileURLWithPath: "/tmp"))
        let webView = try #require(cache.webView(for: profile) { _ in } as? RecordingWebView)
        let url = try #require(URL(string: "http://127.0.0.1:65432/"))
        cache.navigate(url, for: profile)
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
                            userInfo: [NSURLErrorFailingURLErrorKey: url])
        webView.navigationDelegate?.webView?(webView, didFailProvisionalNavigation: nil, withError: error)
        #expect(cache.state(for: profile).errorMessage != nil)
        cache.reload(for: profile)
        #expect(webView.requests.map(\.url).suffix(2) == [url, url])
    }

    @Test func queuedURLLoadsOnFirstVisitAndRemovalDropsCache() throws {
        let cache = cache()
        let profile = RobloxProfile(name: "Test", colorName: "blue", rootDirectory: URL(fileURLWithPath: "/tmp"))
        let url = try #require(URL(string: "https://www.roblox.com/games/123"))
        cache.navigate(url, for: profile)
        let first = try #require(cache.webView(for: profile) { _ in } as? RecordingWebView)
        #expect(first.requests.map(\.url) == [url])
        cache.removeWebView(for: profile)
        let replacement = try #require(cache.webView(for: profile) { _ in } as? RecordingWebView)
        #expect(first !== replacement)
        #expect(first.navigationDelegate == nil)
        #expect(replacement.requests.first?.url == URL(string: "https://www.roblox.com/"))
    }
}
