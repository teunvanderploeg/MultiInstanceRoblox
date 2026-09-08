import AppKit
import Foundation
import WebKit

@MainActor
final class RobloxLauncher: ObservableObject {
    @Published private(set) var statuses: [UUID: ProfileStatus] = [:]
    @Published private(set) var messages: [UUID: String] = [:]
    @Published private(set) var metrics: [UUID: RunningMetric] = [:]
    @Published private(set) var operations: [UUID: String] = [:]
    @Published private(set) var cloneHealthCache: [UUID: CloneHealth] = [:]
    @Published private(set) var installedVersion: String?

    private let sourceRobloxURL: URL
    private var runningApps: [UUID: [NSRunningApplication]] = [:]
    private var refreshing = false

    init(sourceURL: URL = URL(fileURLWithPath: "/Applications/Roblox.app", isDirectory: true)) {
        sourceRobloxURL = sourceURL
    }

    func status(for profile: RobloxProfile) -> ProfileStatus {
        if runningApps[profile.id]?.contains(where: { !$0.isTerminated }) == true { return .running }
        return statuses[profile.id] ?? .missingClone
    }

    func sourceVersion() -> String? { installedVersion }
    func isBusy(_ profile: RobloxProfile) -> Bool { operations[profile.id] != nil }
    func cloneHealth(for profile: RobloxProfile) -> CloneHealth? { cloneHealthCache[profile.id] }

    private func discoverRunningApps(_ profiles: [RobloxProfile]) {
        let apps = NSWorkspace.shared.runningApplications
        for profile in profiles {
            runningApps[profile.id] = apps.filter {
                !$0.isTerminated && $0.bundleURL?.standardizedFileURL == profile.cloneURL.standardizedFileURL
            }
        }
        let ids = Set(profiles.map(\.id))
        runningApps = runningApps.filter { ids.contains($0.key) }
    }

    /// Refresh disk state away from the main actor and reconnect to existing processes.
    func refresh(_ profiles: [RobloxProfile], verify: Bool = false) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        discoverRunningApps(profiles)
        let source = sourceRobloxURL
        let oldHealth = cloneHealthCache
        let available = profiles.filter { !isBusy($0) }
        let pids = runningApps.values.flatMap { $0.map(\.processIdentifier) }
        let result = await Task.detached(priority: .utility) {
            let version = RobloxWorker.version(at: source)
            var health: [UUID: CloneHealth] = [:]
            for profile in available {
                let cloneVersion = RobloxWorker.version(at: profile.cloneURL)
                if !verify, var cached = oldHealth[profile.id], cached.cloneVersion == cloneVersion {
                    cached.sourceVersion = version
                    health[profile.id] = cached
                } else {
                    health[profile.id] = RobloxWorker.health(source: source, clone: profile.cloneURL, verify: true)
                }
            }
            return (version, health, RobloxWorker.metrics(for: pids))
        }.value
        installedVersion = result.0
        for profile in available where !isBusy(profile) {
            guard let health = result.1[profile.id] else { continue }
            cloneHealthCache[profile.id] = health
            statuses[profile.id] = Self.diskStatus(profile: profile, health: health)
        }
        discoverRunningApps(profiles)
        var updated: [UUID: RunningMetric] = [:]
        for profile in profiles {
            let readings = (runningApps[profile.id] ?? []).compactMap { result.2[$0.processIdentifier] }
            if let first = readings.first {
                updated[profile.id] = RunningMetric(processID: first.processID,
                    cpuPercent: readings.reduce(0) { $0 + $1.cpuPercent },
                    memoryMB: readings.reduce(0) { $0 + $1.memoryMB })
            }
        }
        metrics = updated
    }

    nonisolated static func diskStatus(profile: RobloxProfile, health: CloneHealth) -> ProfileStatus {
        guard health.cloneVersion != nil else { return .missingClone }
        guard let source = health.sourceVersion else { return .error("Roblox is not installed at /Applications/Roblox.app") }
        guard profile.lastSourceVersion == source, health.cloneVersion == source else {
            return .staleClone(sourceVersion: source, cloneVersion: health.cloneVersion)
        }
        guard health.executableExists, health.isSigned else { return .error("The Roblox copy failed validation. Repair this profile.") }
        return .ready
    }

    func ensureClone(for profile: RobloxProfile, store: ProfileStore) async {
        discoverRunningApps(store.profiles)
        guard !isBusy(profile) else { return }
        guard status(for: profile) != .running else {
            messages[profile.id] = "Stop this profile before repairing it."
            return
        }
        operations[profile.id] = "Preparing Roblox…"
        defer { operations[profile.id] = nil }
        _ = await prepareClone(profile, store: store)
    }

    private func prepareClone(_ profile: RobloxProfile, store: ProfileStore) async -> Bool {
        let source = sourceRobloxURL
        do {
            let version = try await Task.detached(priority: .userInitiated) {
                try RobloxWorker.build(source: source, profile: profile) { stage in
                    Task { @MainActor [weak self] in
                        guard self?.operations[profile.id] != nil else { return }
                        self?.operations[profile.id] = stage
                    }
                }
            }.value
            store.markCloneUpdated(for: profile, sourceVersion: version)
            installedVersion = version
            cloneHealthCache[profile.id] = await Task.detached(priority: .utility) {
                RobloxWorker.health(source: source, clone: profile.cloneURL, verify: true)
            }.value
            statuses[profile.id] = .ready
            messages[profile.id] = "Roblox copy ready."
            return true
        } catch {
            statuses[profile.id] = .error(error.localizedDescription)
            cloneHealthCache[profile.id] = nil
            messages[profile.id] = error.localizedDescription
            return false
        }
    }

    func launch(_ url: URL, for profile: RobloxProfile, store: ProfileStore) async {
        guard LaunchURL.isNative(url) else { return }
        guard !isBusy(profile) else { return }
        discoverRunningApps(store.profiles)
        operations[profile.id] = "Launching Roblox…"
        defer { operations[profile.id] = nil }
        // Read the installed version immediately before deciding whether to repair.
        let source = sourceRobloxURL
        let health = await Task.detached(priority: .utility) {
            RobloxWorker.health(source: source, clone: profile.cloneURL, verify: true)
        }.value
        installedVersion = health.sourceVersion
        cloneHealthCache[profile.id] = health
        statuses[profile.id] = Self.diskStatus(profile: profile, health: health)
        let action = LaunchAction.forStatus(status(for: profile))
        if action == .prepare, !(await prepareClone(profile, store: store)) { return }
        messages[profile.id] = "Launching Roblox…"
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = action != .reuse
        do {
            let app = try await NSWorkspace.shared.open([url], withApplicationAt: profile.cloneURL, configuration: configuration)
            let existing = runningApps[profile.id] ?? []
            runningApps[profile.id] = existing.filter { !$0.isTerminated && $0.processIdentifier != app.processIdentifier } + [app]
            messages[profile.id] = "Launched \(profile.name)."
        } catch {
            messages[profile.id] = "Roblox refused launch: \(error.localizedDescription)"
        }
    }

    func launch(_ url: URL, for profiles: [RobloxProfile], store: ProfileStore) async {
        for profile in profiles { await launch(url, for: profile, store: store) }
    }

    func repairAll(_ profiles: [RobloxProfile], store: ProfileStore) async {
        await refresh(profiles, verify: true)
        for profile in profiles where status(for: profile).needsRepair {
            await ensureClone(for: profile, store: store)
        }
    }

    func stopAll(_ profiles: [RobloxProfile]) {
        discoverRunningApps(profiles)
        for profile in profiles { stop(profile) }
    }

    func stop(_ profile: RobloxProfile) {
        guard !isBusy(profile) else { return }
        let apps = runningApps[profile.id] ?? []
        guard !apps.isEmpty else { return }
        let accepted = apps.filter { !$0.isTerminated }.map { $0.terminate() }
        messages[profile.id] = accepted.allSatisfy { $0 }
            ? "Stop requested. Waiting for Roblox to exit…"
            : "Roblox could not be stopped. Close its window and try again."
        // Retain process handles until their termination has actually been observed.
    }

    func clearSession(for profile: RobloxProfile, cache: RobloxWebViewCache) async {
        guard !isBusy(profile) else { return }
        operations[profile.id] = "Clearing browser session…"
        defer { operations[profile.id] = nil }
        cache.removeWebView(for: profile)
        let dataStore = WKWebsiteDataStore(forIdentifier: profile.webDataStoreID)
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        cache.navigate(URL(string: "https://www.roblox.com/")!, for: profile)
        messages[profile.id] = "Browser session cleared. Log in again to continue."
    }

    func delete(_ profile: RobloxProfile, store: ProfileStore, cache: RobloxWebViewCache) async {
        discoverRunningApps(store.profiles)
        guard !isBusy(profile) else { return }
        guard status(for: profile) != .running else {
            store.errorMessage = "Stop \(profile.name) before deleting it."
            return
        }
        operations[profile.id] = "Deleting profile…"
        defer { operations[profile.id] = nil }
        cache.removeWebView(for: profile)
        // Let AppKit release any autoreleased view references before removing its store.
        await Task.yield()
        do {
            try await WKWebsiteDataStore.remove(forIdentifier: profile.webDataStoreID)
            let expectedDirectory = store.rootDirectory.appendingPathComponent("Profiles").appendingPathComponent(profile.id.uuidString)
            guard expectedDirectory.standardizedFileURL == profile.profileDirectory.standardizedFileURL else {
                throw WorkerError.command("The profile folder is outside its managed location. No files were deleted.")
            }
            try await Task.detached(priority: .utility) {
                if FileManager.default.fileExists(atPath: expectedDirectory.path) {
                    try FileManager.default.removeItem(at: expectedDirectory)
                }
            }.value
            store.deleteMetadata(id: profile.id)
            statuses[profile.id] = nil
            messages[profile.id] = nil
            cloneHealthCache[profile.id] = nil
            metrics[profile.id] = nil
            runningApps[profile.id] = nil
        } catch {
            store.errorMessage = "Could not finish deleting \(profile.name). The profile is kept so you can retry. \(error.localizedDescription)"
        }
    }

    func arrangeWindows(for profiles: [RobloxProfile], layout: WindowLayout) async {
        discoverRunningApps(profiles)
        let apps = profiles.flatMap { runningApps[$0.id] ?? [] }
        guard !apps.isEmpty else { return }
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let desktopTop = NSScreen.screens.first?.frame.maxY ?? frame.maxY
        let rects = layout.rects(count: apps.count, in: frame)
        let scripts = zip(apps, rects).map { app, rect in
            """
            tell application "System Events"
              repeat with targetProcess in (every process whose unix id is \(app.processIdentifier))
                if (count of windows of targetProcess) > 0 then
                  set position of window 1 of targetProcess to {\(Int(rect.minX)), \(Int(desktopTop - rect.maxY))}
                  set size of window 1 of targetProcess to {\(Int(rect.width)), \(Int(rect.height))}
                end if
              end repeat
            end tell
            """
        }
        do {
            try await Task.detached(priority: .userInitiated) {
                for script in scripts { _ = try RobloxWorker.run("/usr/bin/osascript", ["-e", script], timeout: 15) }
            }.value
        } catch {
            for profile in profiles {
                messages[profile.id] = "Could not arrange windows. Check Accessibility permissions in System Settings. \(error.localizedDescription)"
            }
        }
    }

    func revealFiles(for profile: RobloxProfile) {
        NSWorkspace.shared.activateFileViewerSelecting([profile.profileDirectory])
    }
}
enum WindowLayout: String, CaseIterable, Identifiable {
    case grid
    case columns
    case rows
    case cascade

    var id: String { rawValue }

    var label: String {
        switch self {
        case .grid: "Grid"
        case .columns: "Columns"
        case .rows: "Rows"
        case .cascade: "Cascade"
        }
    }

    func rects(count: Int, in frame: NSRect) -> [NSRect] {
        guard count > 0 else { return [] }
        let gap: CGFloat = 8

        switch self {
        case .grid:
            let columns = Int(ceil(sqrt(Double(count))))
            let rows = Int(ceil(Double(count) / Double(columns)))
            let width = (frame.width - CGFloat(columns - 1) * gap) / CGFloat(columns)
            let height = (frame.height - CGFloat(rows - 1) * gap) / CGFloat(rows)
            return (0..<count).map { index in
                let row = index / columns
                let column = index % columns
                return NSRect(
                    x: frame.minX + CGFloat(column) * (width + gap),
                    y: frame.minY + frame.height - CGFloat(row + 1) * height - CGFloat(row) * gap,
                    width: width,
                    height: height
                )
            }

        case .columns:
            let width = (frame.width - CGFloat(count - 1) * gap) / CGFloat(count)
            return (0..<count).map { index in
                NSRect(x: frame.minX + CGFloat(index) * (width + gap), y: frame.minY, width: width, height: frame.height)
            }

        case .rows:
            let height = (frame.height - CGFloat(count - 1) * gap) / CGFloat(count)
            return (0..<count).map { index in
                NSRect(
                    x: frame.minX,
                    y: frame.minY + frame.height - CGFloat(index + 1) * height - CGFloat(index) * gap,
                    width: frame.width,
                    height: height
                )
            }

        case .cascade:
            let width = frame.width * 0.68
            let height = frame.height * 0.72
            let offset: CGFloat = 34
            return (0..<count).map { index in
                NSRect(
                    x: frame.minX + CGFloat(index) * offset,
                    y: frame.maxY - height - CGFloat(index) * offset,
                    width: width,
                    height: height
                )
            }
        }
    }
}

enum LauncherError: LocalizedError {
    case sourceMissing
    case sourceVersionMissing
    case invalidInfoPlist
    case codesignFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceMissing:
            "Roblox is not installed at /Applications/Roblox.app."
        case .sourceVersionMissing:
            "Could not read the installed Roblox version."
        case .invalidInfoPlist:
            "Could not patch the copied Roblox Info.plist."
        case let .codesignFailed(output):
            "Could not sign the copied Roblox app. \(output)"
        }
    }
}
