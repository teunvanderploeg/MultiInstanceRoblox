import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var launcher: RobloxLauncher
    @EnvironmentObject private var webViewCache: RobloxWebViewCache
    @State private var launcherURLText = ""
    @State private var searchText = ""
    @State private var diagnosticsMessage = ""
    @State private var showInspector = false
    @State private var deletingProfile: RobloxProfile?
    @State private var clearingProfile: RobloxProfile?
    private let metricsTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if store.needsRecovery {
                recoveryView
            } else if let profile = store.selectedProfile {
                profileWorkspace(profile)
            } else {
                ContentUnavailableView {
                    Label("No profiles", systemImage: "person.crop.circle.badge.plus")
                } description: {
                    Text("Add a profile to log in to Roblox.")
                } actions: {
                    Button("Add profile") { store.addProfile() }
                }
            }
        }
        .inspector(isPresented: $showInspector) {
            if let profile = store.selectedProfile, !store.needsRecovery {
                profileInspector(profile)
                    .inspectorColumnWidth(min: 280, ideal: 310, max: 380)
            }
        }
        .task(id: store.profiles.map(\.id)) { await launcher.refresh(store.profiles) }
        .onReceive(metricsTimer) { _ in Task { await launcher.refresh(store.profiles) } }
        .alert("Profile error", isPresented: Binding(
            get: { store.errorMessage != nil && !store.needsRecovery },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .confirmationDialog("Delete \(deletingProfile?.name ?? "profile") and its saved login?", isPresented: Binding(
            get: { deletingProfile != nil }, set: { if !$0 { deletingProfile = nil } }
        ), titleVisibility: .visible) {
            if let profile = deletingProfile {
                Button("Delete profile", role: .destructive) {
                    Task { await launcher.delete(profile, store: store, cache: webViewCache) }
                }
            }
        }
        .confirmationDialog("Clear the saved login for \(clearingProfile?.name ?? "profile")?", isPresented: Binding(
            get: { clearingProfile != nil }, set: { if !$0 { clearingProfile = nil } }
        ), titleVisibility: .visible) {
            if let profile = clearingProfile {
                Button("Clear session", role: .destructive) {
                    Task { await launcher.clearSession(for: profile, cache: webViewCache) }
                }
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            TextField("Search profiles", text: $searchText)
                .textFieldStyle(.roundedBorder).padding(10)
            List(selection: $store.selectedProfileID) {
                ForEach(filteredProfiles) { profile in
                    ProfileRow(profile: profile, status: launcher.status(for: profile), metric: launcher.metrics[profile.id],
                        isSelectedForBulkLaunch: Binding(
                            get: { store.profiles.first { $0.id == profile.id }?.isSelectedForBulkLaunch ?? false },
                            set: { value in store.update(id: profile.id) { $0.isSelectedForBulkLaunch = value } }
                        ))
                        .tag(profile.id)
                        .contextMenu {
                            Button("Duplicate") { store.duplicate(profile) }
                            Button("Reveal files") { launcher.revealFiles(for: profile) }
                            Button("Delete…", role: .destructive) { deletingProfile = profile }
                                .disabled(launcher.isBusy(profile) || launcher.status(for: profile) == .running)
                        }
                }
                .onMove { source, destination in
                    // Filtered offsets do not identify the same rows in the full array.
                    if searchText.isEmpty { store.moveProfiles(from: source, to: destination) }
                }
                .moveDisabled(!searchText.isEmpty)
            }
            HStack {
                Button { store.addProfile() } label: { Label("Add", systemImage: "plus") }
                Spacer()
                Menu {
                    Button("Select all") { store.selectAllForBulkLaunch(true) }
                    Button("Deselect all") { store.selectAllForBulkLaunch(false) }
                } label: { Image(systemName: "checklist") }
                    .menuStyle(.borderlessButton).fixedSize().help("Bulk selection")
            }.padding(12)
        }
        .disabled(store.needsRecovery)
        .navigationSplitViewColumnWidth(min: 220, ideal: 250)
    }

    private func profileWorkspace(_ profile: RobloxProfile) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: profile.symbolName).foregroundStyle(profile.displayColor)
                Text(profile.name).font(.headline).lineLimit(1)
                StatusBadge(status: launcher.status(for: profile))
                if let metric = launcher.metrics[profile.id] {
                    Text("CPU \(metric.cpuPercent, specifier: "%.1f")% · \(Int(metric.memoryMB)) MB")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                if launcher.status(for: profile) == .running {
                    Button("Stop", systemImage: "stop.fill") { launcher.stop(profile) }
                        .disabled(launcher.isBusy(profile))
                }
                Button("Profile details", systemImage: "sidebar.right") { showInspector.toggle() }
                    .labelStyle(.iconOnly).help("Profile details and maintenance")
            }.padding(.horizontal, 12).padding(.top, 10)
            launcherControls(profile).padding(12)
            if let operation = launcher.operations[profile.id] {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(operation).font(.caption)
                    Spacer()
                }.padding(.horizontal, 12).padding(.bottom, 8)
            } else if let message = launcher.messages[profile.id] {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.bottom, 8).textSelection(.enabled)
            }
            Divider()
            if launcher.operations[profile.id] == "Clearing browser session…" || launcher.operations[profile.id] == "Deleting profile…" {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                BrowserPane(profile: profile, state: webViewCache.state(for: profile)) { url in
                    Task { await launcher.launch(url, for: profile, store: store) }
                }
                .id(profile.id)
            }
        }
    }

    private func launcherControls(_ profile: RobloxProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Game URL or search Roblox", text: $launcherURLText)
                    .textFieldStyle(.roundedBorder).onSubmit { openCurrent(profile) }
                Button("Open") { openCurrent(profile) }.disabled(launcher.isBusy(profile))
                Button("Launch \(selectedBulkProfiles.count)", systemImage: "play.fill") {
                    Task { await launchSelected() }
                }
                .disabled(selectedBulkProfiles.isEmpty || selectedBulkProfiles.contains { launcher.isBusy($0) })
                Button("Favorite", systemImage: "star") {
                    if let url = LaunchURL.parse(launcherURLText), !LaunchURL.isNative(url) {
                        store.addFavoriteURL(url.absoluteString, to: profile)
                    }
                }.labelStyle(.iconOnly).help("Save this game page to favorites")
                Menu {
                    Button("Repair all") { Task { await launcher.repairAll(store.profiles, store: store) } }
                    Button("Stop all") { launcher.stopAll(store.profiles) }
                    Divider()
                    ForEach(WindowLayout.allCases) { layout in
                        Button("Arrange: \(layout.label)") {
                            Task { await launcher.arrangeWindows(for: store.profiles, layout: layout) }
                        }
                    }
                    Divider()
                    Button("Export diagnostics") { Task { await exportDiagnostics() } }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().help("Maintenance and window arrangement")
            }
            if !profile.favoriteGameURLs.isEmpty || !profile.recentGameURLs.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    if !profile.favoriteGameURLs.isEmpty {
                        URLList(title: "Favorites", urls: profile.favoriteGameURLs,
                            choose: { launcherURLText = $0; openCurrent(profile) },
                            remove: { store.removeFavoriteURL($0, from: profile) })
                    }
                    if !profile.recentGameURLs.isEmpty {
                        URLList(title: "Recent", urls: profile.recentGameURLs,
                            choose: { launcherURLText = $0; openCurrent(profile) }, remove: nil)
                    }
                }
            }
            if !diagnosticsMessage.isEmpty {
                Text(diagnosticsMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func profileInspector(_ profile: RobloxProfile) -> some View {
        Form {
            Section("Profile") {
                TextField("Name", text: profileBinding(profile.id, \.name, fallback: profile.name))
                Picker("Icon", selection: profileBinding(profile.id, \.symbolName, fallback: profile.symbolName)) {
                    ForEach(ProfileIcon.symbols, id: \.self) { symbol in Label(symbol, systemImage: symbol).tag(symbol) }
                }
                Picker("Color", selection: profileBinding(profile.id, \.colorName, fallback: profile.colorName)) {
                    ForEach(ProfileColor.all) { color in Text(color.id.capitalized).tag(color.id) }
                }
                Text("Notes").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: profileBinding(profile.id, \.notes, fallback: profile.notes)).frame(minHeight: 90)
                Button("Duplicate profile") { store.duplicate(profile) }
            }
            Section("Roblox copy") {
                if let health = launcher.cloneHealth(for: profile) {
                    LabeledContent("Installed", value: health.sourceVersion ?? "Not installed")
                    LabeledContent("Profile", value: health.cloneVersion ?? "Not prepared")
                    Text(health.summary).font(.caption).foregroundStyle(.secondary)
                } else { Text("Checking Roblox…").foregroundStyle(.secondary) }
                Button(launcher.status(for: profile) == .missingClone ? "Set up Roblox" : "Repair Roblox copy") {
                    Task { await launcher.ensureClone(for: profile, store: store) }
                }.disabled(launcher.isBusy(profile) || launcher.status(for: profile) == .running)
                Button("Refresh health") { Task { await launcher.refresh(store.profiles, verify: true) } }
                Button("Reveal files") { launcher.revealFiles(for: profile) }
            }
            Section("Saved data") {
                Button("Clear session…", role: .destructive) { clearingProfile = profile }
                    .disabled(launcher.isBusy(profile))
                Button("Delete profile…", role: .destructive) { deletingProfile = profile }
                    .disabled(launcher.isBusy(profile) || launcher.status(for: profile) == .running)
                if launcher.status(for: profile) == .running {
                    Text("Stop Roblox before repairing or deleting this profile.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.formStyle(.grouped)
    }

    private var recoveryView: some View {
        ContentUnavailableView {
            Label("Your profiles need recovery", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text(store.errorMessage ?? "The saved profiles could not be read.")
            Text("The original file will be kept when you restore a backup or start fresh.")
        } actions: {
            Button("Restore backup") { store.recoverFromBackup() }.disabled(!store.canRestoreBackup)
            Button("Show saved files") { NSWorkspace.shared.open(store.rootDirectory) }
            Button("Start fresh") { store.startFreshAfterRecovery() }
        }
    }

    private func profileBinding(_ id: UUID, _ keyPath: WritableKeyPath<RobloxProfile, String>, fallback: String) -> Binding<String> {
        Binding(get: { store.profiles.first { $0.id == id }?[keyPath: keyPath] ?? fallback },
                set: { value in store.update(id: id) { $0[keyPath: keyPath] = value } })
    }
    private var filteredProfiles: [RobloxProfile] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? store.profiles : store.profiles.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.notes.localizedCaseInsensitiveContains(query)
        }
    }
    private var selectedBulkProfiles: [RobloxProfile] { store.profiles.filter(\.isSelectedForBulkLaunch) }

    private func parsedURL() -> URL? {
        guard let url = LaunchURL.parse(launcherURLText) else {
            diagnosticsMessage = "Enter a game URL or search text. Supported links use https, http, roblox, or roblox-player."
            return nil
        }
        diagnosticsMessage = ""
        return url
    }
    private func openCurrent(_ profile: RobloxProfile) {
        guard !launcher.isBusy(profile), let url = parsedURL() else { return }
        if LaunchURL.isNative(url) {
            Task { await launcher.launch(url, for: profile, store: store) }
        } else {
            webViewCache.navigate(url, for: profile)
            store.recordRecentURL(url.absoluteString, for: profile)
        }
    }
    private func launchSelected() async {
        guard let url = parsedURL() else { return }
        let profiles = selectedBulkProfiles
        if LaunchURL.isNative(url) {
            await launcher.launch(url, for: profiles, store: store)
        } else {
            for profile in profiles {
                webViewCache.navigate(url, for: profile)
                store.recordRecentURL(url.absoluteString, for: profile)
            }
            diagnosticsMessage = "Game pages opened for \(profiles.count) profiles. Select each profile and press Play using its saved login."
        }
    }

    private func exportDiagnostics() async {
        await launcher.refresh(store.profiles, verify: true)
        let lines = store.profiles.map { profile in
            """
            Profile: \(profile.name)
            ID: \(profile.id)
            Status: \(launcher.status(for: profile).label)
            Source version: \(launcher.sourceVersion() ?? "unknown")
            Clone version: \(launcher.cloneHealth(for: profile)?.cloneVersion ?? "unknown")
            Health: \(launcher.cloneHealth(for: profile)?.summary ?? "not checked")
            Bundle ID: \(launcher.cloneHealth(for: profile)?.bundleIdentifier ?? "unknown")
            Process: \(launcher.metrics[profile.id].map { "\($0.processID), CPU \($0.cpuPercent)%, RAM \(Int($0.memoryMB)) MB" } ?? "not running")
            Message: \(launcher.messages[profile.id] ?? "none")
            Clone path: \(profile.clonePath)
            """
        }
        let text = "MultiInstanceRoblox diagnostics\nGenerated: \(Date())\n\n" + lines.joined(separator: "\n\n")
        let output = store.rootDirectory.appendingPathComponent("diagnostics.txt")
        do {
            try await Task.detached(priority: .utility) { try text.write(to: output, atomically: true, encoding: .utf8) }.value
            diagnosticsMessage = "Diagnostics exported."
            NSWorkspace.shared.activateFileViewerSelecting([output])
        } catch { diagnosticsMessage = "Could not export diagnostics: \(error.localizedDescription)" }
    }
}

private struct BrowserPane: View {
    @EnvironmentObject private var cache: RobloxWebViewCache
    let profile: RobloxProfile
    @ObservedObject var state: BrowserState
    let launch: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("Back", systemImage: "chevron.left") { cache.goBack(for: profile) }.disabled(!state.canGoBack)
                Button("Forward", systemImage: "chevron.right") { cache.goForward(for: profile) }.disabled(!state.canGoForward)
                Button("Reload", systemImage: "arrow.clockwise") { cache.reload(for: profile) }
                Button("Home", systemImage: "house") { cache.reloadHome(for: profile) }
                Divider().frame(height: 16)
                Text(state.pageTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if state.isLoading { ProgressView().controlSize(.small) }
            }
            .labelStyle(.iconOnly).buttonStyle(.borderless).padding(.horizontal, 12).padding(.vertical, 8)
            if let error = state.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button("Retry") { cache.reload(for: profile) }
                }.padding(10).background(.quaternary)
            }
            RobloxWebView(profile: profile, onLaunchURL: launch)
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
