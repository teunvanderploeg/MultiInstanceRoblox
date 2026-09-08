import Foundation
import SwiftUI

struct RobloxProfile: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var colorName: String
    var symbolName: String
    var notes: String
    var isSelectedForBulkLaunch: Bool
    var favoriteGameURLs: [String]
    var recentGameURLs: [String]
    var webDataStoreID: UUID
    var clonePath: String
    var lastSourceVersion: String?
    var createdAt: Date
    var updatedAt: Date

    init(name: String, colorName: String, rootDirectory: URL) {
        let id = UUID()
        self.id = id
        self.name = name
        self.colorName = colorName
        self.symbolName = "person.crop.circle"
        self.notes = ""
        self.isSelectedForBulkLaunch = true
        self.favoriteGameURLs = []
        self.recentGameURLs = []
        self.webDataStoreID = UUID()
        self.clonePath = rootDirectory
            .appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent("Roblox-\(id.uuidString.prefix(8)).app", isDirectory: true)
            .path
        self.lastSourceVersion = nil
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var cloneURL: URL {
        URL(fileURLWithPath: clonePath, isDirectory: true)
    }

    var profileDirectory: URL {
        cloneURL.deletingLastPathComponent()
    }

    var displayColor: Color {
        ProfileColor.named(colorName).color
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case colorName
        case symbolName
        case notes
        case isSelectedForBulkLaunch
        case favoriteGameURLs
        case recentGameURLs
        case webDataStoreID
        case clonePath
        case lastSourceVersion
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        colorName = try container.decode(String.self, forKey: .colorName)
        symbolName = try container.decodeIfPresent(String.self, forKey: .symbolName) ?? "person.crop.circle"
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        isSelectedForBulkLaunch = try container.decodeIfPresent(Bool.self, forKey: .isSelectedForBulkLaunch) ?? true
        favoriteGameURLs = try container.decodeIfPresent([String].self, forKey: .favoriteGameURLs) ?? []
        recentGameURLs = try container.decodeIfPresent([String].self, forKey: .recentGameURLs) ?? []
        webDataStoreID = try container.decode(UUID.self, forKey: .webDataStoreID)
        clonePath = try container.decode(String.self, forKey: .clonePath)
        lastSourceVersion = try container.decodeIfPresent(String.self, forKey: .lastSourceVersion)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

struct RunningMetric: Equatable {
    var processID: pid_t
    var cpuPercent: Double
    var memoryMB: Double
}

struct CloneHealth: Equatable {
    var sourceVersion: String?
    var cloneVersion: String?
    var bundleIdentifier: String?
    var isSigned: Bool
    var executableExists: Bool

    var summary: String {
        let signed = isSigned ? "signed" : "not signed"
        let executable = executableExists ? "executable found" : "missing executable"
        return "\(signed), \(executable)"
    }
}

struct ProfileColor: Identifiable, Equatable {
    let id: String
    let color: Color

    static let all: [ProfileColor] = [
        .init(id: "blue", color: .blue),
        .init(id: "green", color: .green),
        .init(id: "orange", color: .orange),
        .init(id: "pink", color: .pink),
        .init(id: "purple", color: .purple),
        .init(id: "red", color: .red),
        .init(id: "teal", color: .teal),
        .init(id: "yellow", color: .yellow)
    ]

    static func named(_ name: String) -> ProfileColor {
        all.first { $0.id == name } ?? all[0]
    }
}

enum ProfileStatus: Equatable {
    case missingClone
    case staleClone(sourceVersion: String, cloneVersion: String?)
    case ready
    case running
    case error(String)

    var label: String {
        switch self {
        case .missingClone:
            "Needs setup"
        case .staleClone:
            "Needs repair"
        case .ready:
            "Ready"
        case .running:
            "Running"
        case .error:
            "Error"
        }
    }
}

extension ProfileStatus {
    var needsRepair: Bool {
        switch self {
        case .missingClone, .staleClone, .error:
            true
        case .ready, .running:
            false
        }
    }
}

/// The launch decision is shared by the launcher and regression tests.
enum LaunchAction: Equatable {
    case reuse, open, prepare

    static func forStatus(_ status: ProfileStatus) -> Self {
        switch status {
        case .running: .reuse
        case .ready: .open
        case .missingClone, .staleClone, .error: .prepare
        }
    }
}

enum LaunchURL {
    static func isNative(_ url: URL) -> Bool {
        ["roblox", "roblox-player"].contains(url.scheme?.lowercased() ?? "")
    }

    static func parse(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            guard ["https", "http", "roblox", "roblox-player"].contains(scheme) else { return nil }
            return url
        }
        var components = URLComponents(string: "https://www.roblox.com/search")!
        components.queryItems = [URLQueryItem(name: "keyword", value: trimmed)]
        return components.url
    }
}
