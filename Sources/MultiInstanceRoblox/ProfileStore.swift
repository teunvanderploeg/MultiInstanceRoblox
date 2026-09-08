import Foundation

@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [RobloxProfile] = []
    @Published var selectedProfileID: UUID?
    @Published var errorMessage: String?
    @Published private(set) var needsRecovery = false

    let rootDirectory: URL
    private let profilesFile: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(rootDirectory: URL? = nil) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.rootDirectory = rootDirectory ?? appSupport.appendingPathComponent("MultiInstanceRoblox", isDirectory: true)
        profilesFile = self.rootDirectory.appendingPathComponent("profiles.json")

        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        load()
        if !FileManager.default.fileExists(atPath: profilesFile.path) && !needsRecovery {
            addProfile(named: "Main")
        }
    }

    var selectedProfile: RobloxProfile? {
        guard let selectedProfileID else { return profiles.first }
        return profiles.first { $0.id == selectedProfileID } ?? profiles.first
    }

    func addProfile(named requestedName: String? = nil) {
        guard !needsRecovery else { return }
        let defaultName = "Account \(profiles.count + 1)"
        let color = ProfileColor.all[profiles.count % ProfileColor.all.count].id
        let profile = RobloxProfile(name: requestedName ?? defaultName, colorName: color, rootDirectory: rootDirectory)
        profiles.append(profile)
        selectedProfileID = profile.id
        save()
    }

    func duplicate(_ profile: RobloxProfile) {
        var copy = RobloxProfile(name: "\(profile.name) Copy", colorName: profile.colorName, rootDirectory: rootDirectory)
        copy.symbolName = profile.symbolName
        copy.notes = profile.notes
        copy.favoriteGameURLs = profile.favoriteGameURLs
        copy.isSelectedForBulkLaunch = profile.isSelectedForBulkLaunch
        profiles.append(copy)
        selectedProfileID = copy.id
        save()
    }

    func update(_ profile: RobloxProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var updated = profile
        updated.updatedAt = Date()
        profiles[index] = updated
        save()
    }

    func update(id: UUID, _ mutate: (inout RobloxProfile) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        mutate(&profiles[index])
        profiles[index].updatedAt = Date()
        save()
    }

    func rename(_ profile: RobloxProfile, to name: String) {
        rename(id: profile.id, to: name)
    }

    func rename(id: UUID, to name: String) {
        update(id: id) { profile in
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedName.isEmpty {
                profile.name = trimmedName
            }
        }
    }

    func setColor(_ profile: RobloxProfile, colorName: String) {
        update(id: profile.id) { $0.colorName = colorName }
    }

    func setColor(id: UUID, colorName: String) {
        update(id: id) { profile in
            profile.colorName = colorName
        }
    }

    func setSymbol(_ profile: RobloxProfile, symbolName: String) {
        update(id: profile.id) { $0.symbolName = symbolName }
    }

    func setSymbol(id: UUID, symbolName: String) {
        update(id: id) { profile in
            profile.symbolName = symbolName
        }
    }

    func setNotes(_ profile: RobloxProfile, notes: String) {
        update(id: profile.id) { $0.notes = notes }
    }

    func setNotes(id: UUID, notes: String) {
        update(id: id) { profile in
            profile.notes = notes
        }
    }

    func setBulkSelection(_ profile: RobloxProfile, isSelected: Bool) {
        update(id: profile.id) { $0.isSelectedForBulkLaunch = isSelected }
    }

    func selectAllForBulkLaunch(_ selected: Bool) {
        profiles = profiles.map { profile in
            var updated = profile
            updated.isSelectedForBulkLaunch = selected
            updated.updatedAt = Date()
            return updated
        }
        save()
    }

    func moveProfiles(from source: IndexSet, to destination: Int) {
        profiles.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func addFavoriteURL(_ urlString: String, to profile: RobloxProfile) {
        let normalized = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        update(id: profile.id) { updated in
            updated.favoriteGameURLs.removeAll { $0 == normalized }
            updated.favoriteGameURLs.insert(normalized, at: 0)
            updated.favoriteGameURLs = Array(updated.favoriteGameURLs.prefix(20))
        }
    }

    func removeFavoriteURL(_ urlString: String, from profile: RobloxProfile) {
        update(id: profile.id) { $0.favoriteGameURLs.removeAll { $0 == urlString } }
    }

    func recordRecentURL(_ urlString: String, for profile: RobloxProfile) {
        let normalized = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        update(id: profile.id) { updated in
            updated.recentGameURLs.removeAll { $0 == normalized }
            updated.recentGameURLs.insert(normalized, at: 0)
            updated.recentGameURLs = Array(updated.recentGameURLs.prefix(12))
        }
    }

    func markCloneUpdated(for profile: RobloxProfile, sourceVersion: String) {
        update(id: profile.id) { $0.lastSourceVersion = sourceVersion }
    }

    /// Metadata is committed only after external profile resources have been removed.
    func deleteMetadata(id: UUID) {
        let previous = profiles
        let selection = selectedProfileID
        profiles.removeAll { $0.id == id }
        if selectedProfileID == id { selectedProfileID = profiles.first?.id }
        if !save() {
            profiles = previous
            selectedProfileID = selection
        }
    }

    var backupFile: URL { rootDirectory.appendingPathComponent("profiles.backup.json") }

    var canRestoreBackup: Bool {
        guard let data = try? Data(contentsOf: backupFile) else { return false }
        return (try? decoder.decode([RobloxProfile].self, from: data)) != nil
    }

    func recoverFromBackup() {
        do {
            let data = try Data(contentsOf: backupFile)
            let recovered = try decoder.decode([RobloxProfile].self, from: data)
            try preserveUnreadableFile()
            try data.write(to: profilesFile, options: .atomic)
            profiles = recovered
            selectedProfileID = profiles.first?.id
            needsRecovery = false
            errorMessage = nil
        } catch {
            errorMessage = "Could not restore backup: \(error.localizedDescription)"
        }
    }

    func startFreshAfterRecovery() {
        do {
            try preserveUnreadableFile()
            // Keep the previous backup available until the new store is established.
            if FileManager.default.fileExists(atPath: profilesFile.path) {
                try FileManager.default.removeItem(at: profilesFile)
            }
            needsRecovery = false
            errorMessage = nil
            profiles = []
            addProfile(named: "Main")
        } catch {
            errorMessage = "Could not preserve existing profiles: \(error.localizedDescription)"
        }
    }

    private func preserveUnreadableFile() throws {
        if FileManager.default.fileExists(atPath: profilesFile.path) {
            let preserved = rootDirectory.appendingPathComponent("profiles.unreadable-\(UUID().uuidString).json")
            try FileManager.default.copyItem(at: profilesFile, to: preserved)
        }
    }

    private func load() {
        do {
            try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            guard FileManager.default.fileExists(atPath: profilesFile.path) else { return }
            let data = try Data(contentsOf: profilesFile)
            profiles = try decoder.decode([RobloxProfile].self, from: data)
            selectedProfileID = profiles.first?.id
        } catch {
            errorMessage = "Could not load profiles. Your saved file has been preserved. \(error.localizedDescription)"
            needsRecovery = true
        }
    }

    @discardableResult
    private func save() -> Bool {
        guard !needsRecovery else { return false }
        do {
            try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            let data = try encoder.encode(profiles)
            if FileManager.default.fileExists(atPath: profilesFile.path) {
                let previous = try Data(contentsOf: profilesFile)
                // Never replace a valid backup with unreadable data.
                _ = try decoder.decode([RobloxProfile].self, from: previous)
                try previous.write(to: backupFile, options: .atomic)
            }
            try data.write(to: profilesFile, options: [.atomic])
            return true
        } catch {
            errorMessage = "Could not save profiles: \(error.localizedDescription)"
            return false
        }
    }
}
