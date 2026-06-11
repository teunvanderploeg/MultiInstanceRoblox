import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var launcher: RobloxLauncher
    @EnvironmentObject private var webViewCache: RobloxWebViewCache

    @State private var launcherURLText = ""
    @State private var requestedURLs: [UUID: URL] = [:]
    @State private var layout: WindowLayout = .grid
    @State private var searchText = ""
    @State private var diagnosticsMessage = ""

    private let metricsTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .onReceive(metricsTimer) { _ in
            launcher.refreshMetrics()
        }
        .alert("Profile Error", isPresented: errorBinding) {
            Button("OK", role: .cancel) {
                store.errorMessage = nil
            }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search profiles", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(10)

            List(selection: $store.selectedProfileID) {
                ForEach(filteredProfiles) { profile in
                    ProfileRow(
                        profile: profile,
                        status: launcher.status(for: profile),
                        metric: launcher.metrics[profile.id],
                        isSelectedForBulkLaunch: Binding(
                            get: { currentProfile(profile.id)?.isSelectedForBulkLaunch ?? profile.isSelectedForBulkLaunch },
                            set: { store.setBulkSelection(profile, isSelected: $0) }
                        )
                    )
                    .tag(profile.id)
                    .contextMenu {
                        Button("Duplicate") {
                            store.duplicate(profile)
                        }
                        Button("Reveal Files") {
                            launcher.revealFiles(for: profile)
                        }
                        Button("Delete", role: .destructive) {
                            store.delete(profile)
                        }
                    }
                }
                .onMove(perform: store.moveProfiles)
            }

            HStack {
                Button {
                    store.addProfile()
                } label: {
                    Label("Add", systemImage: "plus")
                }

                Button {
                    if let profile = store.selectedProfile {
                        store.duplicate(profile)
                    }
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                .disabled(store.selectedProfile == nil)

                Spacer()

                Button {
                    store.selectAllForBulkLaunch(true)
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .help("Select all for bulk launch")

                Button {
                    store.selectAllForBulkLaunch(false)
                } label: {
                    Image(systemName: "circle")
                }
                .help("Clear bulk launch selection")
            }
            .padding(12)
        }
        .navigationSplitViewColumnWidth(min: 270, ideal: 310)
    }

    @ViewBuilder
    private var detail: some View {
        if let profile = store.selectedProfile {
            VStack(spacing: 0) {
                topControls(for: profile)

                Divider()

                RobloxWebView(
                    profile: profile,
                    requestedURL: requestedURLs[profile.id]
                ) { launchURL in
                    store.recordRecentURL(launchURL.absoluteString, for: profile)
                    Task {
                        await launcher.launch(launchURL, for: profile, store: store)
                    }
                }
            }
        } else {
            ContentUnavailableView("No Profile", systemImage: "person.crop.circle.badge.questionmark")
        }
    }

    private func topControls(for profile: RobloxProfile) -> some View {
        VStack(spacing: 12) {
            ProfileHeader(
                profile: profile,
                status: launcher.status(for: profile),
                message: launcher.messages[profile.id],
                metric: launcher.metrics[profile.id],
                rename: { store.rename(id: profile.id, to: $0) },
                setColor: { store.setColor(id: profile.id, colorName: $0) },
                setSymbol: { store.setSymbol(id: profile.id, symbolName: $0) },
                repair: {
                    Task {
                        await launcher.ensureClone(for: profile, store: store)
                    }
                },
                stop: {
                    launcher.stop(profile)
                },
                reveal: {
                    launcher.revealFiles(for: profile)
                }
            )

            LauncherPanel(
                urlText: $launcherURLText,
                layout: $layout,
                selectedCount: selectedBulkProfiles.count,
                recentURLs: profile.recentGameURLs,
                favoriteURLs: profile.favoriteGameURLs,
                diagnosticsMessage: diagnosticsMessage,
                openCurrent: {
                    openURLTextInCurrentProfile(profile)
                },
                launchSelected: {
                    Task {
                        await launchURLTextForSelectedProfiles()
                    }
                },
                repairAll: {
                    Task {
                        await launcher.repairAll(store.profiles, store: store)
                    }
                },
                stopAll: {
                    launcher.stopAll(store.profiles)
                },
                arrange: {
                    launcher.arrangeWindows(for: store.profiles, layout: layout)
                },
                exportDiagnostics: {
                    exportDiagnostics()
                },
                chooseURL: { url in
                    launcherURLText = url
                    openURLTextInCurrentProfile(profile)
                },
                addFavorite: {
                    store.addFavoriteURL(launcherURLText, to: profile)
                },
                removeFavorite: { url in
                    store.removeFavoriteURL(url, from: profile)
                }
            )

            ProfileInspector(
                profile: profile,
                health: launcher.cloneHealth(for: profile),
                setNotes: { store.setNotes(id: profile.id, notes: $0) },
                clearSession: {
                    Task {
                        await launcher.clearSession(for: profile)
                        webViewCache.removeWebView(for: profile)
                        requestedURLs[profile.id] = URL(string: "https://www.roblox.com/")
                    }
                }
            )
        }
        .padding(12)
    }

    private var filteredProfiles: [RobloxProfile] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.profiles }
        return store.profiles.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
                $0.notes.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedBulkProfiles: [RobloxProfile] {
        store.profiles.filter(\.isSelectedForBulkLaunch)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )
    }

    private func currentProfile(_ id: UUID) -> RobloxProfile? {
        store.profiles.first { $0.id == id }
    }

    private func parsedLauncherURL() -> URL? {
        let trimmed = launcherURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        return URL(string: "https://www.roblox.com/search?keyword=\(trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed)")
    }

    private func openURLTextInCurrentProfile(_ profile: RobloxProfile) {
        guard let url = parsedLauncherURL() else { return }
        requestedURLs[profile.id] = url
        store.recordRecentURL(url.absoluteString, for: profile)
    }

    private func launchURLTextForSelectedProfiles() async {
        guard let url = parsedLauncherURL() else { return }

        if url.scheme == "roblox" || url.scheme == "roblox-player" {
            for profile in selectedBulkProfiles {
                store.recordRecentURL(url.absoluteString, for: profile)
            }
            await launcher.launch(url, for: selectedBulkProfiles, store: store)
        } else {
            for profile in selectedBulkProfiles {
                requestedURLs[profile.id] = url
                store.recordRecentURL(url.absoluteString, for: profile)
            }
            diagnosticsMessage = "Web URLs were queued into selected profile browsers. Select each profile and press Play from its logged-in Roblox page."
        }
    }

    private func exportDiagnostics() {
        let lines = store.profiles.map { profile in
            let status = launcher.status(for: profile)
            let health = launcher.cloneHealth(for: profile, forceRefresh: true)
            let metric = launcher.metrics[profile.id]
            return """
            Profile: \(profile.name)
            ID: \(profile.id.uuidString)
            Status: \(status.label)
            Source version: \(health.sourceVersion ?? "unknown")
            Clone version: \(health.cloneVersion ?? "unknown")
            Bundle ID: \(health.bundleIdentifier ?? "unknown")
            Health: \(health.summary)
            Process: \(metric.map { "\($0.processID), CPU \($0.cpuPercent)%, RAM \(Int($0.memoryMB)) MB" } ?? "not running")
            Clone path: \(profile.clonePath)
            """
        }

        let text = """
        MultiInstanceRoblox Diagnostics
        Generated: \(Date())
        Roblox source: /Applications/Roblox.app
        Source version: \(launcher.sourceVersion() ?? "unknown")

        \(lines.joined(separator: "\n\n"))
        """

        let outputURL = store.rootDirectory.appendingPathComponent("diagnostics.txt")
        do {
            try FileManager.default.createDirectory(at: store.rootDirectory, withIntermediateDirectories: true)
            try text.write(to: outputURL, atomically: true, encoding: .utf8)
            diagnosticsMessage = "Diagnostics exported to \(outputURL.path)"
            NSWorkspace.shared.activateFileViewerSelecting([outputURL])
        } catch {
            diagnosticsMessage = "Could not export diagnostics: \(error.localizedDescription)"
        }
    }
}

private struct ProfileRow: View {
    let profile: RobloxProfile
    let status: ProfileStatus
    let metric: RunningMetric?
    @Binding var isSelectedForBulkLaunch: Bool

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $isSelectedForBulkLaunch)
                .labelsHidden()
                .toggleStyle(.checkbox)

            Image(systemName: profile.symbolName)
                .foregroundStyle(profile.displayColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(profile.name)
                    .font(.body)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(status.label)
                        .foregroundStyle(statusColor)
                    if let metric {
                        Text("\(Int(metric.memoryMB)) MB")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch status {
        case .ready:
            .secondary
        case .running:
            .green
        case .missingClone, .staleClone:
            .orange
        case .error:
            .red
        }
    }
}

private struct ProfileHeader: View {
    let profile: RobloxProfile
    let status: ProfileStatus
    let message: String?
    let metric: RunningMetric?
    let rename: (String) -> Void
    let setColor: (String) -> Void
    let setSymbol: (String) -> Void
    let repair: () -> Void
    let stop: () -> Void
    let reveal: () -> Void

    @State private var editedName: String = ""

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                TextField("Profile name", text: $editedName)
                    .onSubmit {
                        rename(editedName)
                    }
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onAppear {
                    editedName = profile.name
                }
                .onChange(of: profile.id) {
                    editedName = profile.name
                }

                Picker("Icon", selection: Binding(
                    get: { profile.symbolName },
                    set: { setSymbol($0) }
                )) {
                    ForEach(ProfileIcon.symbols, id: \.self) { symbol in
                        Label(symbol, systemImage: symbol).tag(symbol)
                    }
                }
                .frame(width: 150)

                Picker("Color", selection: Binding(
                    get: { profile.colorName },
                    set: { setColor($0) }
                )) {
                    ForEach(ProfileColor.all) { color in
                        Text(color.id.capitalized).tag(color.id)
                    }
                }
                .frame(width: 130)

                StatusBadge(status: status)

                if let metric {
                    Text("CPU \(metric.cpuPercent, specifier: "%.1f")%  RAM \(Int(metric.memoryMB)) MB")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: repair) {
                    Label(repairTitle, systemImage: "wrench.and.screwdriver")
                }

                Button(action: stop) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(!isRunning)

                Button(action: reveal) {
                    Label("Files", systemImage: "folder")
                }
            }

            if let message, !message.isEmpty {
                HStack {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                }
            }
        }
    }

    private var repairTitle: String {
        switch status {
        case .missingClone:
            "Set Up"
        case .staleClone:
            "Repair"
        default:
            "Repair"
        }
    }

    private var isRunning: Bool {
        if case .running = status {
            true
        } else {
            false
        }
    }
}

private struct LauncherPanel: View {
    @Binding var urlText: String
    @Binding var layout: WindowLayout
    let selectedCount: Int
    let recentURLs: [String]
    let favoriteURLs: [String]
    let diagnosticsMessage: String
    let openCurrent: () -> Void
    let launchSelected: () -> Void
    let repairAll: () -> Void
    let stopAll: () -> Void
    let arrange: () -> Void
    let exportDiagnostics: () -> Void
    let chooseURL: (String) -> Void
    let addFavorite: () -> Void
    let removeFavorite: (String) -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                TextField("Roblox game URL, private-server URL, roblox-player URL, or search text", text: $urlText)
                    .textFieldStyle(.roundedBorder)

                Button(action: openCurrent) {
                    Label("Open", systemImage: "safari")
                }

                Button(action: launchSelected) {
                    Label("Launch \(selectedCount)", systemImage: "play.fill")
                }
                .disabled(selectedCount == 0)

                Button(action: addFavorite) {
                    Image(systemName: "star")
                }
                .help("Add current URL to favorites")
            }

            HStack(spacing: 8) {
                Button(action: repairAll) {
                    Label("Repair All", systemImage: "arrow.triangle.2.circlepath")
                }

                Button(action: stopAll) {
                    Label("Stop All", systemImage: "stop.circle")
                }

                Picker("Layout", selection: $layout) {
                    ForEach(WindowLayout.allCases) { layout in
                        Text(layout.label).tag(layout)
                    }
                }
                .frame(width: 150)

                Button(action: arrange) {
                    Label("Arrange", systemImage: "rectangle.3.group")
                }

                Button(action: exportDiagnostics) {
                    Label("Export Diagnostics", systemImage: "doc.text.magnifyingglass")
                }

                Spacer()
            }

            if !favoriteURLs.isEmpty || !recentURLs.isEmpty {
                HStack(alignment: .top, spacing: 18) {
                    URLList(title: "Favorites", urls: favoriteURLs, choose: chooseURL, remove: removeFavorite)
                    URLList(title: "Recent", urls: recentURLs, choose: chooseURL, remove: nil)
                }
            }

            if !diagnosticsMessage.isEmpty {
                HStack {
                    Text(diagnosticsMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                }
            }
        }
    }
}

private struct URLList: View {
    let title: String
    let urls: [String]
    let choose: (String) -> Void
    let remove: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(urls, id: \.self) { url in
                        HStack(spacing: 4) {
                            Button(shortLabel(for: url)) {
                                choose(url)
                            }
                            .buttonStyle(.bordered)

                            if let remove {
                                Button {
                                    remove(url)
                                } label: {
                                    Image(systemName: "xmark")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shortLabel(for url: String) -> String {
        guard let parsed = URL(string: url) else {
            return String(url.prefix(32))
        }

        if parsed.scheme == "roblox-player" || parsed.scheme == "roblox" {
            return parsed.scheme ?? "Roblox"
        }

        let path = parsed.pathComponents.dropFirst().prefix(3).joined(separator: "/")
        return path.isEmpty ? (parsed.host ?? String(url.prefix(32))) : path
    }
}

private struct ProfileInspector: View {
    let profile: RobloxProfile
    let health: CloneHealth
    let setNotes: (String) -> Void
    let clearSession: () -> Void

    @State private var notes = ""

    var body: some View {
        DisclosureGroup {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Installed Roblox: \(health.sourceVersion ?? "unknown")")
                    Text("Profile Roblox: \(health.cloneVersion ?? "not built")")
                    Text("Bundle: \(health.bundleIdentifier ?? "not built")")
                    Text("Health: \(health.summary)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 320, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Notes")
                        .font(.caption.weight(.semibold))
                    TextEditor(text: $notes)
                        .frame(height: 58)
                        .onAppear {
                            notes = profile.notes
                        }
                        .onChange(of: profile.id) {
                            notes = profile.notes
                        }
                        .onChange(of: notes) {
                            setNotes(notes)
                        }
                }

                Button(role: .destructive, action: clearSession) {
                    Label("Clear Session", systemImage: "eraser")
                }
            }
            .padding(.top, 8)
        } label: {
            Label("Profile Details", systemImage: "info.circle")
                .font(.caption.weight(.semibold))
        }
    }
}

private struct StatusBadge: View {
    let status: ProfileStatus

    var body: some View {
        Text(status.label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(background, in: Capsule())
    }

    private var foreground: Color {
        switch status {
        case .running:
            .green
        case .ready:
            .primary
        case .missingClone, .staleClone:
            .orange
        case .error:
            .red
        }
    }

    private var background: Color {
        foreground.opacity(0.14)
    }
}

private enum ProfileIcon {
    static let symbols = [
        "person.crop.circle",
        "gamecontroller",
        "star.circle",
        "bolt.circle",
        "flame.circle",
        "crown",
        "moon.circle",
        "sun.max.circle",
        "sparkles",
        "shield"
    ]
}
