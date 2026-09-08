import Foundation

/// Blocking filesystem and process work. Call from a detached task, never a view update.
enum RobloxWorker {
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 60) throws -> String {
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                throw WorkerError.command("The operation timed out: \(executable)")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let text = String(decoding: try Data(contentsOf: outputURL), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw WorkerError.command(text) }
        return text
    }

    static func version(at app: URL) -> String? {
        guard let plist = try? plist(at: app) else { return nil }
        let parts = [plist["CFBundleShortVersionString"] as? String, plist["CFBundleVersion"] as? String].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "-")
    }

    static func plist(at app: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw LauncherError.invalidInfoPlist
        }
        return plist
    }

    /// Prepare and validate the replacement before touching the current copy.
    /// Keeping staging and backup beside the destination makes the moves same-volume.
    static func install(source: URL, destination: URL, prepare: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent("staging-\(UUID().uuidString).app")
        let backup = parent.appendingPathComponent("previous-\(UUID().uuidString).app")
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: source, to: staging)
        try prepare(staging)
        let hadPrevious = fm.fileExists(atPath: destination.path)
        if hadPrevious { try fm.moveItem(at: destination, to: backup) }
        do {
            try fm.moveItem(at: staging, to: destination)
        } catch {
            if hadPrevious {
                do { try fm.moveItem(at: backup, to: destination) }
                catch { throw WorkerError.command("Replacement failed. The previous copy is preserved at \(backup.path). \(error.localizedDescription)") }
            }
            throw error
        }
        if hadPrevious { try? fm.removeItem(at: backup) }
    }

    static func build(source: URL, profile: RobloxProfile, progress: @Sendable (String) -> Void) throws -> String {
        guard let version = version(at: source) else { throw LauncherError.sourceMissing }
        progress("Copying Roblox…")
        try install(source: source, destination: profile.cloneURL) { staging in
            progress("Preparing profile…")
            var info = try plist(at: staging)
            info["CFBundleIdentifier"] = "dev.local.MultiInstanceRoblox.Roblox.\(profile.id.uuidString)"
            info["CFBundleName"] = "Roblox \(profile.name)"
            info["LSMultipleInstancesProhibited"] = false
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: staging.appendingPathComponent("Contents/Info.plist"), options: .atomic)
            progress("Signing Roblox…")
            _ = try run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", staging.path], timeout: 180)
            progress("Verifying Roblox…")
            _ = try run("/usr/bin/codesign", ["--verify", "--deep", staging.path])
            guard FileManager.default.isExecutableFile(atPath: staging.appendingPathComponent("Contents/MacOS/RobloxPlayer").path) else {
                throw WorkerError.command("The Roblox copy is missing its executable.")
            }
            guard self.version(at: source) == version else {
                throw WorkerError.command("Roblox updated during preparation. Try repairing again.")
            }
        }
        return version
    }

    static func health(source: URL, clone: URL, verify: Bool) -> CloneHealth {
        CloneHealth(
            sourceVersion: version(at: source),
            cloneVersion: version(at: clone),
            bundleIdentifier: (try? plist(at: clone))?["CFBundleIdentifier"] as? String,
            isSigned: verify && (try? run("/usr/bin/codesign", ["--verify", "--deep", clone.path])) != nil,
            executableExists: FileManager.default.isExecutableFile(atPath: clone.appendingPathComponent("Contents/MacOS/RobloxPlayer").path)
        )
    }

    static func metrics(for pids: [pid_t]) -> [pid_t: RunningMetric] {
        guard !pids.isEmpty,
              let text = try? run("/bin/ps", ["-p", pids.map(String.init).joined(separator: ","), "-o", "pid=,%cpu=,rss="], timeout: 5) else { return [:] }
        var result: [pid_t: RunningMetric] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            guard parts.count == 3, let pid = pid_t(parts[0]), let cpu = Double(parts[1]), let rss = Double(parts[2]) else { continue }
            result[pid] = RunningMetric(processID: pid, cpuPercent: cpu, memoryMB: rss / 1024)
        }
        return result
    }
}

enum WorkerError: LocalizedError {
    case command(String)
    var errorDescription: String? { switch self { case .command(let message): message } }
}
