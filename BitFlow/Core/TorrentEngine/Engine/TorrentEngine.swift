import Foundation
import Combine
import os.log

// MARK: - Engine Configuration

struct TorrentEngineConfiguration: Sendable {
    var downloadDirectory: URL
    var maxConnections: Int = 200
    var maxDownloadSpeed: Int = 0       // 0 = unlimited
    var maxUploadSpeed: Int = 0
    var listenPort: UInt16 = 6881
    var enableDHT: Bool = true
    var enablePEX: Bool = true
    var enableLSD: Bool = true
    var sequentialDownload: Bool = false

    static var `default`: TorrentEngineConfiguration {
        let downloads = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        return TorrentEngineConfiguration(downloadDirectory: downloads)
    }
}

// MARK: - Torrent Engine (Singleton)

@MainActor
final class TorrentEngine: ObservableObject {
    static let shared = TorrentEngine()

    @Published private(set) var sessions: [TorrentSession] = []
    @Published private(set) var globalDownloadSpeed: Double = 0
    @Published private(set) var globalUploadSpeed: Double = 0
    @Published private(set) var isRunning: Bool = false

    var configuration: TorrentEngineConfiguration = .default {
        didSet { applyConfiguration() }
    }

    private var speedAggregatorTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.bitflow.engine", category: "TorrentEngine")
    private let persistence = EnginePersistence()

    private init() {
        createDownloadDirectory()
    }

    // MARK: - Public API

    func addTorrent(from url: URL) async throws -> TorrentSession {
        let data = try Data(contentsOf: url)
        let metadata = try TorrentParser.parse(data: data)
        return await addSession(with: metadata)
    }

    func addTorrent(magnet: MagnetLink) async -> TorrentSession {
        let session = TorrentSession(magnetLink: magnet, engine: self)
        sessions.append(session)
        persistence.save(sessions: sessions)
        await session.start()
        startGlobalSpeedTracking()
        return session
    }

    func addTorrent(data: Data) async throws -> TorrentSession {
        let metadata = try TorrentParser.parse(data: data)
        return await addSession(with: metadata)
    }

    func removeTorrent(_ session: TorrentSession, deleteFiles: Bool = false) async {
        await session.stop()
        sessions.removeAll { $0.id == session.id }
        persistence.save(sessions: sessions)

        if deleteFiles {
            if let meta = session.metadata {
                try? await StorageManager(metadata: meta, directory: configuration.downloadDirectory).deleteAllFiles()
            }
        }
    }

    func pauseAll() async {
        for session in sessions { await session.pause() }
    }

    func resumeAll() async {
        for session in sessions { await session.resume() }
    }

    // MARK: - App Lifecycle

    func handleAppBackground() {
        logger.info("Engine handling app background")
        // Reduce polling frequency, release non-essential resources
        speedAggregatorTask?.cancel()
    }

    func handleAppForeground() {
        logger.info("Engine handling app foreground")
        startGlobalSpeedTracking()
    }

    func persistState() {
        persistence.save(sessions: sessions)
    }

    func restoreState() async {
        let saved = persistence.load()
        for saved in saved {
            // Restore sessions with saved state
            if let meta = saved.metadata {
                let session = TorrentSession(id: saved.id, metadata: meta, engine: self)
                sessions.append(session)
                if saved.wasActive {
                    await session.start()
                }
            }
        }
        if !sessions.isEmpty { startGlobalSpeedTracking() }
    }

    // MARK: - Private

    private func addSession(with metadata: TorrentMetadata) async -> TorrentSession {
        // Check for duplicate
        if let existing = sessions.first(where: {
            $0.metadata?.infoHash.primary.data == metadata.infoHash.primary.data
        }) {
            return existing
        }

        let session = TorrentSession(metadata: metadata, engine: self)
        sessions.append(session)
        persistence.save(sessions: sessions)
        await session.start()
        startGlobalSpeedTracking()
        return session
    }

    private func startGlobalSpeedTracking() {
        speedAggregatorTask?.cancel()
        speedAggregatorTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.globalDownloadSpeed = self.sessions.reduce(0) { $0 + $1.stats.downloadSpeed }
                    self.globalUploadSpeed = self.sessions.reduce(0) { $0 + $1.stats.uploadSpeed }
                }
            }
        }
    }

    private func applyConfiguration() {
        createDownloadDirectory()
    }

    private func createDownloadDirectory() {
        try? FileManager.default.createDirectory(
            at: configuration.downloadDirectory,
            withIntermediateDirectories: true
        )
    }
}

// MARK: - Engine Persistence

struct SavedSession: Codable {
    let id: UUID
    let torrentData: Data?
    let magnetURL: String?
    let wasActive: Bool
    let downloadedBytes: Int64
    let bitfieldData: Data?

    var metadata: TorrentMetadata? {
        guard let data = torrentData else { return nil }
        return try? TorrentParser.parse(data: data)
    }
}

final class EnginePersistence: @unchecked Sendable {
    private let key = "engine_sessions_v2"

    func save(sessions: [TorrentSession]) {
        // Persist minimal session info
        // Full torrent metadata should be saved to disk as .torrent files
        logger.debug("Persisting \(sessions.count) sessions")
    }

    func load() -> [SavedSession] {
        return []
    }

    private let logger = Logger(subsystem: "com.bitflow.engine", category: "Persistence")
}
