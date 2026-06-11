import AppKit
import Foundation
import WebKit

@MainActor
final class RobloxLauncher: ObservableObject {
    @Published private(set) var statuses: [UUID: ProfileStatus] = [:]
    @Published private(set) var messages: [UUID: String] = [:]
    @Published private(set) var metrics: [UUID: RunningMetric] = [:]

    private let sourceRobloxURL = URL(fileURLWithPath: "/Applications/Roblox.app", isDirectory: true)
    private var runningApps: [UUID: NSRunningApplication] = [:]
    private var cachedSourceVersion: String?
    private var cloneHealthCache: [UUID: CloneHealth] = [:]

    func status(for profile: RobloxProfile) -> ProfileStatus {
        if let app = runningApps[profile.id] {
            if !app.isTerminated {
                return .running
            }
            runningApps[profile.id] = nil
            return refreshStatus(for: profile)
        }
        if let status = statuses[profile.id] {
            return status
        }
        return refreshStatus(for: profile)
    }

    func sourceVersion() -> String? {
        cachedSourceVersion ?? refreshSourceVersion()
    }

    @discardableResult
    func refreshStatus(for profile: RobloxProfile) -> ProfileStatus {
        let status = computedStatus(for: profile)
        statuses[profile.id] = status
        return status
    }

    func cloneHealth(for profile: RobloxProfile, forceRefresh: Bool = false) -> CloneHealth {
        if !forceRefresh, let health = cloneHealthCache[profile.id] {
            return health
        }
        return refreshCloneHealth(for: profile)
    }

    @discardableResult
    func refreshCloneHealth(for profile: RobloxProfile) -> CloneHealth {
        let cloneBundle = Bundle(url: profile.cloneURL)
        let bundleIdentifier = cloneBundle?.bundleIdentifier
        let cloneVersion = bundleVersion(at: profile.cloneURL)
        let executableExists = FileManager.default.fileExists(
            atPath: profile.cloneURL.appendingPathComponent("Contents/MacOS/RobloxPlayer").path
        )
        let health = CloneHealth(
            sourceVersion: sourceVersion(),
            cloneVersion: cloneVersion,
            bundleIdentifier: bundleIdentifier,
            isSigned: isBundleSigned(profile.cloneURL),
            executableExists: executableExists
        )
        cloneHealthCache[profile.id] = health
        return health
    }

    func ensureClone(for profile: RobloxProfile, store: ProfileStore) async {
        messages[profile.id] = "Preparing Roblox copy..."

        do {
            let version = try currentSourceVersion()
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: profile.profileDirectory, withIntermediateDirectories: true)

            if fileManager.fileExists(atPath: profile.cloneURL.path) {
                try fileManager.removeItem(at: profile.cloneURL)
            }

            try fileManager.copyItem(at: sourceRobloxURL, to: profile.cloneURL)
            try patchInfoPlist(for: profile)
            try signBundle(at: profile.cloneURL)

            store.markCloneUpdated(for: profile, sourceVersion: version)
            statuses[profile.id] = .ready
            refreshCloneHealth(for: profile)
            messages[profile.id] = "Roblox copy ready."
        } catch {
            statuses[profile.id] = .error(error.localizedDescription)
            cloneHealthCache[profile.id] = nil
            messages[profile.id] = error.localizedDescription
        }
    }

    func launch(_ launchURL: URL, for profile: RobloxProfile, store: ProfileStore) async {
        if case .ready = status(for: profile) {
            await openLaunchURL(launchURL, for: profile)
            return
        }

        await ensureClone(for: profile, store: store)
        guard case .ready = status(for: profile) else { return }
        await openLaunchURL(launchURL, for: profile)
    }

    func launch(_ launchURL: URL, for profiles: [RobloxProfile], store: ProfileStore) async {
        for profile in profiles {
            await launch(launchURL, for: profile, store: store)
        }
    }

    func repairAll(_ profiles: [RobloxProfile], store: ProfileStore) async {
        for profile in profiles {
            if status(for: profile).needsRepair {
                await ensureClone(for: profile, store: store)
            }
        }
    }

    func stopAll(_ profiles: [RobloxProfile]) {
        for profile in profiles {
            stop(profile)
        }
    }

    func stop(_ profile: RobloxProfile) {
        guard let app = runningApps[profile.id], !app.isTerminated else {
            runningApps[profile.id] = nil
            refreshStatus(for: profile)
            return
        }

        app.terminate()
        messages[profile.id] = "Stop requested."
        runningApps[profile.id] = nil
        refreshStatus(for: profile)
    }

    func refreshMetrics() {
        var updated: [UUID: RunningMetric] = [:]
        var terminatedProfileIDs: [UUID] = []

        for (profileID, app) in runningApps {
            guard !app.isTerminated else {
                terminatedProfileIDs.append(profileID)
                continue
            }

            let processID = app.processIdentifier
            let metric = readMetric(for: processID)
            updated[profileID] = metric
        }

        for profileID in terminatedProfileIDs {
            runningApps[profileID] = nil
            statuses[profileID] = nil
        }

        metrics = updated
    }

    func clearSession(for profile: RobloxProfile) async {
        messages[profile.id] = "Clearing browser session..."

        let dataStore = WKWebsiteDataStore(forIdentifier: profile.webDataStoreID)
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await dataStore.dataRecords(ofTypes: dataTypes)
        await dataStore.removeData(ofTypes: dataTypes, for: records)

        messages[profile.id] = "Browser session cleared. Reload the profile page to log in again."
        refreshCloneHealth(for: profile)
    }

    func arrangeWindows(for profiles: [RobloxProfile], layout: WindowLayout) {
        let runningProfiles = profiles.compactMap { profile -> (RobloxProfile, NSRunningApplication)? in
            guard let app = runningApps[profile.id], !app.isTerminated else { return nil }
            return (profile, app)
        }

        guard !runningProfiles.isEmpty else { return }

        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let rects = layout.rects(count: runningProfiles.count, in: frame)

        for (index, item) in runningProfiles.enumerated() {
            let rect = rects[index]
            runAppleScript(
                """
                tell application "System Events"
                  set targetProcesses to every process whose unix id is \(item.1.processIdentifier)
                  repeat with targetProcess in targetProcesses
                    if (count of windows of targetProcess) > 0 then
                      set position of window 1 of targetProcess to {\(Int(rect.minX)), \(Int(frame.maxY - rect.maxY))}
                      set size of window 1 of targetProcess to {\(Int(rect.width)), \(Int(rect.height))}
                    end if
                  end repeat
                end tell
                """
            )
        }
    }

    func revealFiles(for profile: RobloxProfile) {
        NSWorkspace.shared.activateFileViewerSelecting([profile.profileDirectory])
    }

    private func openLaunchURL(_ launchURL: URL, for profile: RobloxProfile) async {
        messages[profile.id] = "Launching Roblox..."

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true

        do {
            let app = try await NSWorkspace.shared.open(
                [launchURL],
                withApplicationAt: profile.cloneURL,
                configuration: configuration
            )
            runningApps[profile.id] = app
            statuses[profile.id] = .running
            messages[profile.id] = "Launched \(profile.name)."
        } catch {
            statuses[profile.id] = .error(error.localizedDescription)
            messages[profile.id] = "Roblox refused launch: \(error.localizedDescription)"
        }
    }

    private func computedStatus(for profile: RobloxProfile) -> ProfileStatus {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: profile.cloneURL.path) else {
            return .missingClone
        }

        guard let sourceVersion = sourceVersion() else {
            return .error("Roblox is not installed at /Applications/Roblox.app")
        }

        if profile.lastSourceVersion != sourceVersion {
            return .staleClone(sourceVersion: sourceVersion, cloneVersion: profile.lastSourceVersion)
        }

        return .ready
    }

    private func currentSourceVersion() throws -> String {
        guard FileManager.default.fileExists(atPath: sourceRobloxURL.path) else {
            throw LauncherError.sourceMissing
        }
        guard let version = refreshSourceVersion() else {
            throw LauncherError.sourceVersionMissing
        }
        return version
    }

    private func refreshSourceVersion() -> String? {
        let version = bundleVersion(at: sourceRobloxURL)
        cachedSourceVersion = version
        return version
    }

    private func bundleVersion(at appURL: URL) -> String? {
        guard let bundle = Bundle(url: appURL) else { return nil }
        let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        return switch (shortVersion, build) {
        case let (.some(shortVersion), .some(build)):
            "\(shortVersion)-\(build)"
        case let (.some(shortVersion), .none):
            shortVersion
        case let (.none, .some(build)):
            build
        default:
            nil
        }
    }

    private func patchInfoPlist(for profile: RobloxProfile) throws {
        let plistURL = profile.cloneURL.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: plistURL)
        var format = PropertyListSerialization.PropertyListFormat.xml

        guard var plist = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any] else {
            throw LauncherError.invalidInfoPlist
        }

        plist["CFBundleIdentifier"] = "dev.local.MultiInstanceRoblox.Roblox.\(profile.id.uuidString)"
        plist["CFBundleName"] = "Roblox \(profile.name)"
        plist["LSMultipleInstancesProhibited"] = false

        let patched = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try patched.write(to: plistURL, options: [.atomic])
    }

    private func signBundle(at appURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--deep", "--sign", "-", appURL.path]

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? "codesign failed"
            throw LauncherError.codesignFailed(output)
        }
    }

    private func isBundleSigned(_ appURL: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", appURL.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func readMetric(for processID: pid_t) -> RunningMetric {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(processID)", "-o", "%cpu=,rss="]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            let parts = output.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            let cpu = parts.first.flatMap { Double($0) } ?? 0
            let rssKB = parts.dropFirst().first.flatMap { Double($0) } ?? 0
            return RunningMetric(processID: processID, cpuPercent: cpu, memoryMB: rssKB / 1024)
        } catch {
            return RunningMetric(processID: processID, cpuPercent: 0, memoryMB: 0)
        }
    }

    private func runAppleScript(_ script: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Window arrangement is best effort because it depends on Accessibility permission.
        }
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
