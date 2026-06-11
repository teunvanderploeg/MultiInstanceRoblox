import Foundation

@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [RobloxProfile] = []
    @Published var selectedProfileID: UUID?
    @Published var errorMessage: String?

    let rootDirectory: URL
    private let profilesFile: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        rootDirectory = appSupport.appendingPathComponent("MultiInstanceRoblox", isDirectory: true)
        profilesFile = rootDirectory.appendingPathComponent("profiles.json")

        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        load()
        if profiles.isEmpty {
            addProfile(named: "Main")
        }
    }

    var selectedProfile: RobloxProfile? {
        guard let selectedProfileID else { return profiles.first }
        return profiles.first { $0.id == selectedProfileID } ?? profiles.first
    }

    func addProfile(named requestedName: String? = nil) {
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
        var updated = profile
        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? profile.name : name
        update(updated)
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
        var updated = profile
        updated.colorName = colorName
        update(updated)
    }

    func setColor(id: UUID, colorName: String) {
        update(id: id) { profile in
            profile.colorName = colorName
        }
    }

    func setSymbol(_ profile: RobloxProfile, symbolName: String) {
        var updated = profile
        updated.symbolName = symbolName
        update(updated)
    }

    func setSymbol(id: UUID, symbolName: String) {
        update(id: id) { profile in
            profile.symbolName = symbolName
        }
    }

    func setNotes(_ profile: RobloxProfile, notes: String) {
        var updated = profile
        updated.notes = notes
        update(updated)
    }

    func setNotes(id: UUID, notes: String) {
        update(id: id) { profile in
            profile.notes = notes
        }
    }

    func setBulkSelection(_ profile: RobloxProfile, isSelected: Bool) {
        var updated = profile
        updated.isSelectedForBulkLaunch = isSelected
        update(updated)
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
        var updated = profile
        updated.favoriteGameURLs.removeAll { $0 == normalized }
        updated.favoriteGameURLs.insert(normalized, at: 0)
        updated.favoriteGameURLs = Array(updated.favoriteGameURLs.prefix(20))
        update(updated)
    }

    func removeFavoriteURL(_ urlString: String, from profile: RobloxProfile) {
        var updated = profile
        updated.favoriteGameURLs.removeAll { $0 == urlString }
        update(updated)
    }

    func recordRecentURL(_ urlString: String, for profile: RobloxProfile) {
        let normalized = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        var updated = profile
        updated.recentGameURLs.removeAll { $0 == normalized }
        updated.recentGameURLs.insert(normalized, at: 0)
        updated.recentGameURLs = Array(updated.recentGameURLs.prefix(12))
        update(updated)
    }

    func markCloneUpdated(for profile: RobloxProfile, sourceVersion: String) {
        var updated = profile
        updated.lastSourceVersion = sourceVersion
        update(updated)
    }

    func delete(_ profile: RobloxProfile) {
        profiles.removeAll { $0.id == profile.id }
        if selectedProfileID == profile.id {
            selectedProfileID = profiles.first?.id
        }

        do {
            if FileManager.default.fileExists(atPath: profile.profileDirectory.path) {
                try FileManager.default.removeItem(at: profile.profileDirectory)
            }
            save()
        } catch {
            errorMessage = "Could not delete profile files: \(error.localizedDescription)"
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
            errorMessage = "Could not load profiles: \(error.localizedDescription)"
            profiles = []
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            let data = try encoder.encode(profiles)
            try data.write(to: profilesFile, options: [.atomic])
        } catch {
            errorMessage = "Could not save profiles: \(error.localizedDescription)"
        }
    }
}
