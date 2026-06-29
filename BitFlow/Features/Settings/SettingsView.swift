import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var vm: SettingsViewModel

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Downloads
                Section("Downloads") {
                    HStack {
                        Label("Download Location", systemImage: "folder.fill")
                        Spacer()
                        Text("Documents/Downloads")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Toggle(isOn: $vm.sequentialDownload) {
                        Label("Sequential Download", systemImage: "list.number")
                    }

                    Stepper("Max Connections: \(vm.maxConnections)", value: $vm.maxConnections, in: 10...500, step: 10)

                    Picker("Listen Port", selection: $vm.listenPort) {
                        Text("6881").tag(6881)
                        Text("6889").tag(6889)
                        Text("Random").tag(0)
                    }
                }

                // MARK: Speed Limits
                Section("Speed Limits") {
                    SpeedLimitRow(label: "Download", limit: $vm.maxDownloadSpeed)
                    SpeedLimitRow(label: "Upload", limit: $vm.maxUploadSpeed)
                }

                // MARK: Network
                Section("Network") {
                    Toggle(isOn: $vm.enableDHT) {
                        Label("DHT", systemImage: "network")
                    }
                    Toggle(isOn: $vm.enablePEX) {
                        Label("Peer Exchange (PEX)", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Toggle(isOn: $vm.enableLSD) {
                        Label("Local Service Discovery", systemImage: "wifi")
                    }
                    Toggle(isOn: $vm.allowCellular) {
                        Label("Allow Cellular", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }

                // MARK: Appearance
                Section("Appearance") {
                    Picker("Theme", selection: $vm.theme) {
                        Text("System").tag(Theme.system)
                        Text("Light").tag(Theme.light)
                        Text("Dark").tag(Theme.dark)
                    }
                    .pickerStyle(.segmented)
                }

                // MARK: Behavior
                Section("Behavior") {
                    Toggle(isOn: $vm.startDownloadsImmediately) {
                        Label("Start Downloads Immediately", systemImage: "bolt.fill")
                    }
                    Toggle(isOn: $vm.seedAfterComplete) {
                        Label("Seed After Completion", systemImage: "arrow.up.circle")
                    }
                    Stepper("Seed Ratio: \(vm.seedRatio, specifier: "%.1f")x", value: $vm.seedRatio, in: 0...10, step: 0.1)
                }

                // MARK: Background
                Section {
                    NavigationLink(destination: BackgroundSettingsView()) {
                        Label("Background Execution", systemImage: "clock.arrow.2.circlepath")
                    }
                } header: {
                    Text("Background")
                } footer: {
                    Text("iOS limits background network access for BitTorrent. See Background Execution settings for details.")
                        .font(.caption)
                }

                // MARK: Logs
                Section("Diagnostics") {
                    NavigationLink(destination: LogsView()) {
                        Label("View Logs", systemImage: "doc.text.magnifyingglass")
                    }
                }

                // MARK: About
                Section("About") {
                    HStack {
                        Text("BitFlow")
                        Spacer()
                        Text("1.0.0")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Protocol Support")
                        Spacer()
                        Text("BT v1 + v2 + Hybrid")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}

// MARK: - Speed Limit Row

struct SpeedLimitRow: View {
    let label: String
    @Binding var limit: Int  // KB/s, 0 = unlimited

    var displayValue: String {
        limit == 0 ? "Unlimited" : "\(limit) KB/s"
    }

    var body: some View {
        HStack {
            Text("\(label) Limit")
            Spacer()
            Text(displayValue)
                .foregroundStyle(.secondary)
                .font(.subheadline)
        }
        .contentShape(Rectangle())
        // In production: show a speed picker sheet on tap
    }
}

// MARK: - Background Settings

struct BackgroundSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Warning banner
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("iOS Background Limitations")
                            .font(.headline)
                        Text("Continuous BitTorrent downloading in the background is NOT possible on iOS without jailbreak.")
                            .font(.caption)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.title2)
                }
                .padding()
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))

                // Detailed explanation
                GroupBox("Why Background Downloading Is Limited") {
                    VStack(alignment: .leading, spacing: 8) {
                        LimitationRow(
                            icon: "xmark.circle.fill",
                            color: .red,
                            title: "Raw TCP/UDP Sockets",
                            description: "iOS suspends all raw socket connections when the app is backgrounded. BitTorrent requires persistent TCP connections that iOS kills."
                        )
                        LimitationRow(
                            icon: "xmark.circle.fill",
                            color: .red,
                            title: "Background URLSession",
                            description: "URLSession background downloads only work for HTTP/HTTPS. BitTorrent's peer protocol cannot use this API."
                        )
                        LimitationRow(
                            icon: "checkmark.circle.fill",
                            color: .green,
                            title: "BGProcessingTask",
                            description: "iOS may grant up to ~30 minutes of background time when the device is idle. BitFlow uses this to continue downloads opportunistically."
                        )
                        LimitationRow(
                            icon: "checkmark.circle.fill",
                            color: .green,
                            title: "State Persistence",
                            description: "All download progress is saved to disk. Downloads resume instantly when you open the app."
                        )
                        LimitationRow(
                            icon: "checkmark.circle.fill",
                            color: .green,
                            title: "Screen-On Downloading",
                            description: "BitFlow downloads at full speed while the app is in the foreground. Lock screen = paused network."
                        )
                    }
                }
                .padding(.horizontal)
            }
            .padding()
        }
        .navigationTitle("Background Execution")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LimitationRow: View {
    let icon: String
    let color: Color
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Logs View

struct LogsView: View {
    @State private var logs: [LogEntry] = LogManager.shared.entries

    var body: some View {
        List(logs.reversed()) { entry in
            HStack(alignment: .top, spacing: 8) {
                Text(entry.level.emoji)
                    .font(.caption)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.message)
                        .font(.caption.monospaced())
                        .lineLimit(3)
                    Text(entry.timestamp.formatted(.dateTime.hour().minute().second()))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Clear") { LogManager.shared.clear() }
        }
        .onReceive(LogManager.shared.$entries) { logs = $0.reversed() }
    }
}

// MARK: - Storage Manager View

struct StorageManagerView: View {
    @EnvironmentObject var vm: TorrentListViewModel
    @State private var totalUsed: Int64 = 0
    @State private var available: Int64 = 0

    var body: some View {
        NavigationStack {
            List {
                Section("Disk Space") {
                    StorageGaugeView(used: totalUsed, available: available)
                        .listRowBackground(Color.clear)
                }

                Section("Downloads Folder") {
                    ForEach(vm.engine.sessions) { session in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(session.torrentName)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Text("\(session.stats.totalSize.byteCountString) • \(Int(session.stats.progressPercent))%")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                vm.removeTorrent(session, deleteFiles: true)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .navigationTitle("Storage")
            .task { await loadStorageInfo() }
        }
    }

    private func loadStorageInfo() async {
        let fm = FileManager.default
        let docDir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let values = try? docDir.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey]) {
            available = Int64(values.volumeAvailableCapacity ?? 0)
        }
        totalUsed = vm.engine.sessions.reduce(0) { $0 + $1.stats.downloaded }
    }
}

struct StorageGaugeView: View {
    let used: Int64
    let available: Int64

    var total: Int64 { used + available }
    var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    var body: some View {
        VStack(spacing: 8) {
            ProgressView(value: fraction)
                .tint(fraction > 0.9 ? .red : fraction > 0.7 ? .orange : .blue)
                .scaleEffect(x: 1, y: 2)

            HStack {
                Text("Used: \(used.byteCountString)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Free: \(available.byteCountString)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical)
    }
}
