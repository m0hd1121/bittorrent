import SwiftUI
import Charts

struct TorrentDetailView: View {
    @ObservedObject var session: TorrentSession
    @State private var selectedTab = DetailTab.overview

    enum DetailTab: String, CaseIterable {
        case overview = "Overview"
        case files = "Files"
        case peers = "Peers"
        case trackers = "Trackers"
        case pieces = "Pieces"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Header Card
                TorrentHeaderCard(session: session)
                    .padding(.horizontal)

                // Speed Chart
                SpeedChartView(history: session.speedHistory)
                    .frame(height: 120)
                    .padding(.horizontal)

                // Tab Picker
                Picker("", selection: $selectedTab) {
                    ForEach(DetailTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                // Tab Content
                switch selectedTab {
                case .overview:  OverviewTab(session: session)
                case .files:     FilesTab(session: session)
                case .peers:     PeersTab(session: session)
                case .trackers:  TrackersTab(session: session)
                case .pieces:    PiecesTab(session: session)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(session.torrentName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                TorrentControlButtons(session: session)
            }
        }
    }
}

// MARK: - Header Card

struct TorrentHeaderCard: View {
    @ObservedObject var session: TorrentSession

    var body: some View {
        VStack(spacing: 12) {
            // Progress ring
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: session.stats.progress)
                    .stroke(session.state.progressColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut, value: session.stats.progress)
                VStack(spacing: 2) {
                    Text("\(Int(session.stats.progressPercent))%")
                        .font(.title2.bold())
                    Text(session.state.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 100, height: 100)

            // Stat grid
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                StatCell(title: "↓ Speed", value: session.stats.downloadSpeed.speedString)
                StatCell(title: "↑ Speed", value: session.stats.uploadSpeed.speedString)
                StatCell(title: "ETA", value: session.stats.etaString)
                StatCell(title: "Downloaded", value: session.stats.downloaded.byteCountString)
                StatCell(title: "Uploaded", value: session.stats.uploaded.byteCountString)
                StatCell(title: "Ratio", value: String(format: "%.2f", session.stats.ratio))
                StatCell(title: "Seeds", value: "\(session.stats.seeders)")
                StatCell(title: "Peers", value: "\(session.stats.peers)")
                StatCell(title: "Size", value: session.stats.totalSize.byteCountString)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct StatCell: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Speed Chart

struct SpeedChartView: View {
    let history: [Double]

    var chartData: [(index: Int, speed: Double)] {
        history.enumerated().map { (index: $0.offset, speed: $0.element) }
    }

    var body: some View {
        Chart(chartData, id: \.index) { point in
            AreaMark(
                x: .value("Time", point.index),
                y: .value("Speed", point.speed / 1024)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [.blue.opacity(0.6), .blue.opacity(0.1)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            LineMark(
                x: .value("Time", point.index),
                y: .value("Speed", point.speed / 1024)
            )
            .foregroundStyle(.blue)
        }
        .chartYAxis {
            AxisMarks { value in
                if let speed = value.as(Double.self) {
                    AxisValueLabel { Text("\(Int(speed)) KB/s") }
                }
            }
        }
        .chartXAxis(.hidden)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Overview Tab

struct OverviewTab: View {
    @ObservedObject var session: TorrentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let meta = session.metadata {
                InfoRow(label: "Hash", value: meta.infoHash.primary.description)
                InfoRow(label: "Comment", value: meta.comment ?? "—")
                InfoRow(label: "Created by", value: meta.createdBy ?? "—")
                InfoRow(label: "Created", value: meta.creationDate?.formatted() ?? "—")
                InfoRow(label: "Piece size", value: "\(Int(meta.pieceLength / 1024)) KB")
                InfoRow(label: "Pieces", value: "\(meta.pieceCount)")
                InfoRow(label: "Private", value: meta.isPrivate ? "Yes" : "No")
                InfoRow(label: "Files", value: "\(meta.files.count)")
            }

            if let error = session.error {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .padding()
                .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal)
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .lineLimit(3)
            Spacer()
        }
        Divider()
    }
}

// MARK: - Files Tab

struct FilesTab: View {
    @ObservedObject var session: TorrentSession

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(session.files) { file in
                FileRowView(file: file)
                Divider().padding(.leading, 40)
            }
        }
        .padding(.horizontal)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }
}

struct FileRowView: View {
    let file: TorrentFileEntry

    var icon: String {
        let ext = file.filename.split(separator: ".").last?.lowercased() ?? ""
        switch ext {
        case "mp4", "mkv", "avi", "mov": return "film.fill"
        case "mp3", "flac", "aac", "wav": return "music.note"
        case "pdf": return "doc.richtext.fill"
        case "zip", "rar", "7z": return "archivebox.fill"
        case "jpg", "jpeg", "png", "gif": return "photo.fill"
        default: return "doc.fill"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.filename)
                    .font(.subheadline)
                    .lineLimit(1)
                if file.path.count > 1 {
                    Text(file.path.dropLast().joined(separator: "/"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(file.length.byteCountString)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal)
    }
}

// MARK: - Peers Tab

struct PeersTab: View {
    @ObservedObject var session: TorrentSession

    var body: some View {
        if session.peers.isEmpty {
            Text("No connected peers")
                .foregroundStyle(.secondary)
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .padding()
        } else {
            LazyVStack(spacing: 0) {
                ForEach(session.peers) { peer in
                    PeerRowView(peer: peer)
                    Divider().padding(.leading, 16)
                }
            }
            .padding(.horizontal)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)
        }
    }
}

struct PeerRowView: View {
    let peer: PeerDetail

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "network")
                .foregroundStyle(.secondary)
                .font(.caption)

            VStack(alignment: .leading, spacing: 2) {
                Text(peer.id)
                    .font(.caption)
                    .monospaced()
                HStack {
                    if peer.isChoked {
                        Text("Choked")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    if peer.isInterested {
                        Text("Interested")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if peer.downloadSpeed > 0 {
                    Text("↓ \(peer.downloadSpeed.speedString)")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
                if peer.uploadSpeed > 0 {
                    Text("↑ \(peer.uploadSpeed.speedString)")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal)
    }
}

// MARK: - Trackers Tab

struct TrackersTab: View {
    @ObservedObject var session: TorrentSession

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(session.trackerStatuses) { status in
                TrackerRowView(status: status)
                Divider().padding(.leading, 16)
            }
        }
        .padding(.horizontal)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }
}

struct TrackerRowView: View {
    let status: TrackerStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(status.isWorking ? Color.green : .red)
                    .frame(width: 8, height: 8)
                Text(status.url)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            HStack {
                Text(status.statusMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if status.seeders > 0 || status.leechers > 0 {
                    Text("S:\(status.seeders) L:\(status.leechers)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let next = status.nextAnnounce {
                Text("Next: \(next, formatter: Self.relativeFormatter)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}

// MARK: - Pieces Tab

struct PiecesTab: View {
    @ObservedObject var session: TorrentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Piece Map")
                .font(.subheadline.bold())
                .padding(.horizontal)

            if let meta = session.metadata {
                PieceMapView(pieceCount: meta.pieceCount, progress: session.stats.progress)
                    .frame(height: 80)
                    .padding(.horizontal)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal)
            }
        }
    }
}

struct PieceMapView: View {
    let pieceCount: Int
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            let cellSize: CGFloat = max(2, geo.size.width / CGFloat(min(pieceCount, 200)))
            let cols = max(1, Int(geo.size.width / cellSize))
            let rows = max(1, Int(ceil(Double(pieceCount) / Double(cols))))
            let completedCount = Int(Double(pieceCount) * progress)

            Canvas { context, size in
                for i in 0..<pieceCount {
                    let col = CGFloat(i % cols)
                    let row = CGFloat(i / cols)
                    let rect = CGRect(
                        x: col * cellSize + 1,
                        y: row * cellSize + 1,
                        width: cellSize - 1,
                        height: cellSize - 1
                    )
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 1),
                        with: .color(i < completedCount ? .blue : .secondary.opacity(0.3))
                    )
                }
            }
        }
    }
}

// MARK: - Control Buttons

struct TorrentControlButtons: View {
    @ObservedObject var session: TorrentSession

    var body: some View {
        Group {
            switch session.state {
            case .downloading:
                Button { Task { await session.pause() } } label: {
                    Image(systemName: "pause.fill")
                }
            case .paused, .stopped:
                Button { Task { await session.resume() } } label: {
                    Image(systemName: "play.fill")
                }
            default:
                EmptyView()
            }

            Menu {
                Button { Task { await session.recheck() } } label: {
                    Label("Force Recheck", systemImage: "arrow.clockwise")
                }
                Button {
                    // Share/export
                } label: {
                    Label("Share Files", systemImage: "square.and.arrow.up")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}
