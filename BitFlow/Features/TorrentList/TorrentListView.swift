import SwiftUI

struct ContentView: View {
    @EnvironmentObject var torrentVM: TorrentListViewModel

    var body: some View {
        TabView {
            TorrentListView()
                .tabItem {
                    Label("Downloads", systemImage: "arrow.down.circle.fill")
                }

            CompletedView()
                .tabItem {
                    Label("Completed", systemImage: "checkmark.circle.fill")
                }

            StorageManagerView()
                .tabItem {
                    Label("Storage", systemImage: "internaldrive.fill")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
        .sheet(isPresented: $torrentVM.showAddSheet) {
            AddTorrentView()
        }
        .onOpenURL { url in
            torrentVM.handleIncomingURL(url)
        }
    }
}

// MARK: - Torrent List

struct TorrentListView: View {
    @EnvironmentObject var vm: TorrentListViewModel
    @State private var searchText = ""
    @State private var sortOrder = SortOrder.name
    @State private var showingStats = false

    enum SortOrder: String, CaseIterable {
        case name = "Name"
        case progress = "Progress"
        case speed = "Speed"
        case size = "Size"
        case added = "Date Added"
    }

    var filteredSessions: [TorrentSession] {
        vm.activeSessions
            .filter { searchText.isEmpty || $0.torrentName.localizedCaseInsensitiveContains(searchText) }
            .sorted(by: sortComparator)
    }

    var sortComparator: (TorrentSession, TorrentSession) -> Bool {
        switch sortOrder {
        case .name:     return { $0.torrentName < $1.torrentName }
        case .progress: return { $0.stats.progress > $1.stats.progress }
        case .speed:    return { $0.stats.downloadSpeed > $1.stats.downloadSpeed }
        case .size:     return { $0.stats.totalSize > $1.stats.totalSize }
        case .added:    return { $0.id.uuidString > $1.id.uuidString }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if filteredSessions.isEmpty && searchText.isEmpty {
                    EmptyStateView()
                } else {
                    List {
                        if !vm.globalStats.isEmpty {
                            GlobalStatsBar()
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets())
                        }

                        ForEach(filteredSessions) { session in
                            NavigationLink(destination: TorrentDetailView(session: session)) {
                                TorrentRowView(session: session)
                            }
                            .listRowBackground(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(.ultraThinMaterial)
                                    .padding(.horizontal, 4)
                            )
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    vm.removeTorrent(session, deleteFiles: false)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }

                                Button {
                                    vm.removeTorrent(session, deleteFiles: true)
                                } label: {
                                    Label("Delete Files", systemImage: "trash.fill")
                                }
                                .tint(.red)
                            }
                            .swipeActions(edge: .leading) {
                                if session.state == .downloading {
                                    Button {
                                        Task { await session.pause() }
                                    } label: {
                                        Label("Pause", systemImage: "pause.fill")
                                    }
                                    .tint(.orange)
                                } else if session.state == .paused {
                                    Button {
                                        Task { await session.resume() }
                                    } label: {
                                        Label("Resume", systemImage: "play.fill")
                                    }
                                    .tint(.green)
                                }
                            }
                            .contextMenu {
                                TorrentContextMenu(session: session)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .refreshable { await vm.refresh() }
                }
            }
            .navigationTitle("BitFlow")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: "Search torrents")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Picker("Sort By", selection: $sortOrder) {
                            ForEach(SortOrder.allCases, id: \.self) { order in
                                Text(order.rawValue).tag(order)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                }

                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        vm.pauseOrResumeAll()
                    } label: {
                        Image(systemName: vm.allPaused ? "play.circle" : "pause.circle")
                    }

                    Button {
                        vm.showAddSheet = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                    }
                }
            }
        }
    }
}

// MARK: - Torrent Row

struct TorrentRowView: View {
    @ObservedObject var session: TorrentSession
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                StateIndicator(state: session.state)
                Text(session.torrentName)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(session.stats.state.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Progress bar
            ProgressView(value: session.stats.progress)
                .tint(session.state.progressColor)
                .scaleEffect(x: 1, y: 1.5)

            HStack {
                // Download speed
                if session.stats.downloadSpeed > 0 {
                    Label(session.stats.downloadSpeed.speedString, systemImage: "arrow.down")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }

                // Upload speed
                if session.stats.uploadSpeed > 0 {
                    Label(session.stats.uploadSpeed.speedString, systemImage: "arrow.up")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Spacer()

                // ETA or ratio
                if session.state == .seeding {
                    Text("↑ \(session.stats.ratio, specifier: "%.2f")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let eta = session.stats.eta {
                    Text(session.stats.etaString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Size
                Text(session.stats.totalSize.byteCountString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .animation(.easeInOut(duration: 0.3), value: session.stats.progress)
    }
}

// MARK: - State Indicator

struct StateIndicator: View {
    let state: TorrentState

    var body: some View {
        Image(systemName: state.iconName)
            .font(.caption)
            .foregroundStyle(state.progressColor)
            .symbolEffect(.pulse, isActive: state == .downloading)
    }
}

// MARK: - Global Stats Bar

struct GlobalStatsBar: View {
    @EnvironmentObject var vm: TorrentListViewModel

    var body: some View {
        HStack {
            Label(vm.globalDownloadSpeed.speedString, systemImage: "arrow.down.circle.fill")
                .font(.caption)
                .foregroundStyle(.blue)

            Spacer()

            Label("\(vm.activeCount) active", systemImage: "bolt.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Label(vm.globalUploadSpeed.speedString, systemImage: "arrow.up.circle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

// MARK: - Empty State

struct EmptyStateView: View {
    @EnvironmentObject var vm: TorrentListViewModel

    var body: some View {
        ContentUnavailableView {
            Label("No Torrents", systemImage: "arrow.down.doc.fill")
        } description: {
            Text("Add a torrent file or magnet link to start downloading")
        } actions: {
            Button("Add Torrent") {
                vm.showAddSheet = true
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Context Menu

struct TorrentContextMenu: View {
    let session: TorrentSession

    var body: some View {
        Group {
            if session.state == .paused {
                Button { Task { await session.resume() } } label: {
                    Label("Resume", systemImage: "play.fill")
                }
            } else if session.state == .downloading {
                Button { Task { await session.pause() } } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
            }

            Button { Task { await session.recheck() } } label: {
                Label("Force Recheck", systemImage: "arrow.clockwise")
            }

            Divider()

            Button(role: .destructive) {
                // Remove without deleting
            } label: {
                Label("Remove", systemImage: "minus.circle")
            }

            Button(role: .destructive) {
                // Remove + delete
            } label: {
                Label("Delete Files", systemImage: "trash.fill")
            }
        }
    }
}

// MARK: - Completed View

struct CompletedView: View {
    @EnvironmentObject var vm: TorrentListViewModel

    var completedSessions: [TorrentSession] {
        vm.engine.sessions.filter { $0.state == .seeding }
    }

    var body: some View {
        NavigationStack {
            if completedSessions.isEmpty {
                ContentUnavailableView(
                    "No Completed Downloads",
                    systemImage: "checkmark.circle",
                    description: Text("Completed torrents will appear here")
                )
                .navigationTitle("Completed")
            } else {
                List(completedSessions) { session in
                    NavigationLink(destination: TorrentDetailView(session: session)) {
                        TorrentRowView(session: session)
                    }
                }
                .listStyle(.plain)
                .navigationTitle("Completed")
            }
        }
    }
}

// MARK: - Extensions

extension TorrentState {
    var displayName: String {
        switch self {
        case .queued: return "Queued"
        case .checkingFiles: return "Checking"
        case .downloading: return "Downloading"
        case .seeding: return "Seeding"
        case .paused: return "Paused"
        case .error: return "Error"
        case .stopped: return "Stopped"
        case .metadataFetch: return "Fetching Metadata"
        }
    }

    var iconName: String {
        switch self {
        case .downloading: return "arrow.down.circle.fill"
        case .seeding: return "arrow.up.circle.fill"
        case .paused: return "pause.circle.fill"
        case .error: return "exclamationmark.circle.fill"
        case .stopped: return "stop.circle.fill"
        case .checkingFiles: return "magnifyingglass.circle.fill"
        case .metadataFetch: return "clock.circle.fill"
        case .queued: return "list.number"
        }
    }

    var progressColor: Color {
        switch self {
        case .downloading: return .blue
        case .seeding: return .green
        case .paused: return .orange
        case .error: return .red
        case .checkingFiles: return .purple
        default: return .secondary
        }
    }
}

extension Double {
    var speedString: String {
        if self < 1024 { return String(format: "%.0f B/s", self) }
        if self < 1024 * 1024 { return String(format: "%.1f KB/s", self / 1024) }
        if self < 1024 * 1024 * 1024 { return String(format: "%.2f MB/s", self / (1024 * 1024)) }
        return String(format: "%.2f GB/s", self / (1024 * 1024 * 1024))
    }
}

extension Int64 {
    var byteCountString: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: self)
    }
}
