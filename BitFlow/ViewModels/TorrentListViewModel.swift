import SwiftUI
import Combine

@MainActor
final class TorrentListViewModel: ObservableObject {
    @Published var showAddSheet = false

    let engine: TorrentEngine
    private var cancellables = Set<AnyCancellable>()

    var sessions: [TorrentSession] { engine.sessions }
    var activeSessions: [TorrentSession] { engine.sessions.filter { $0.state != .seeding } }
    var globalDownloadSpeed: Double { engine.globalDownloadSpeed }
    var globalUploadSpeed: Double { engine.globalUploadSpeed }
    var allPaused: Bool { engine.sessions.allSatisfy { $0.state == .paused || $0.state == .stopped } }
    var activeCount: Int { engine.sessions.filter { $0.state == .downloading }.count }
    var globalStats: String { "\(activeCount)" }

    init(engine: TorrentEngine) {
        self.engine = engine

        // Propagate engine changes to this VM
        engine.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func handleIncomingURL(_ url: URL) {
        Task {
            if url.scheme?.lowercased() == "magnet" {
                guard let magnet = try? MagnetLink(url: url) else { return }
                _ = await engine.addTorrent(magnet: magnet)
            } else if url.pathExtension.lowercased() == "torrent" {
                _ = try? await engine.addTorrent(from: url)
            }
        }
    }

    func removeTorrent(_ session: TorrentSession, deleteFiles: Bool) {
        Task { await engine.removeTorrent(session, deleteFiles: deleteFiles) }
    }

    func pauseOrResumeAll() {
        Task {
            if allPaused {
                await engine.resumeAll()
            } else {
                await engine.pauseAll()
            }
        }
    }

    func refresh() async {
        // Trigger tracker re-announce, refresh stats
        objectWillChange.send()
    }
}
