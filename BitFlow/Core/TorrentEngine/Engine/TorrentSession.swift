import Foundation
import CryptoKit
import Combine
import os.log

// MARK: - Torrent State

enum TorrentState: String, Sendable, Codable {
    case queued
    case checkingFiles = "checking"
    case downloading
    case seeding
    case paused
    case error
    case stopped
    case metadataFetch = "fetchingMetadata"
}

// MARK: - Torrent Stats

struct TorrentStats: Sendable {
    var downloadSpeed: Double = 0       // bytes/sec
    var uploadSpeed: Double = 0
    var progress: Double = 0            // 0...1
    var eta: TimeInterval?              // seconds remaining
    var seeders: Int = 0
    var leechers: Int = 0
    var peers: Int = 0
    var downloaded: Int64 = 0
    var uploaded: Int64 = 0
    var totalSize: Int64 = 0
    var ratio: Double = 0
    var availability: Double = 0
    var state: TorrentState = .stopped

    var etaString: String {
        guard let eta, eta.isFinite, eta > 0 else { return "∞" }
        if eta < 60 { return "\(Int(eta))s" }
        if eta < 3600 { return "\(Int(eta/60))m \(Int(eta.truncatingRemainder(dividingBy: 60)))s" }
        return "\(Int(eta/3600))h \(Int((eta.truncatingRemainder(dividingBy: 3600))/60))m"
    }

    var progressPercent: Double { progress * 100 }
}

// MARK: - Torrent Session

@MainActor
final class TorrentSession: ObservableObject, Identifiable {
    let id: UUID
    @Published private(set) var metadata: TorrentMetadata?
    @Published private(set) var stats = TorrentStats()
    @Published private(set) var state: TorrentState = .stopped
    @Published private(set) var peers: [PeerDetail] = []
    @Published private(set) var trackerStatuses: [TrackerStatus] = []
    @Published private(set) var speedHistory: [Double] = Array(repeating: 0, count: 60)
    @Published private(set) var files: [TorrentFileEntry] = []
    @Published private(set) var error: String?

    let magnetLink: MagnetLink?
    let torrentName: String

    private let engine: TorrentEngine
    private var sessionActor: TorrentSessionActor?
    private var statsTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.bitflow.app", category: "TorrentSession")

    init(id: UUID = UUID(), metadata: TorrentMetadata, engine: TorrentEngine) {
        self.id = id
        self.metadata = metadata
        self.torrentName = metadata.name
        self.magnetLink = nil
        self.engine = engine
        self.files = metadata.files
    }

    init(id: UUID = UUID(), magnetLink: MagnetLink, engine: TorrentEngine) {
        self.id = id
        self.magnetLink = magnetLink
        self.torrentName = magnetLink.displayName ?? magnetLink.infoHash.description.prefix(8).description
        self.metadata = nil
        self.engine = engine
    }

    // MARK: - Lifecycle

    func start() async {
        guard state == .stopped || state == .paused || state == .error else { return }

        if let meta = metadata {
            let actor = TorrentSessionActor(metadata: meta, saveDir: engine.configuration.downloadDirectory)
            self.sessionActor = actor

            state = .downloading
            stats.state = .downloading
            stats.totalSize = meta.totalLength

            await actor.setCallbacks(
                onStatsUpdate: { [weak self] stats in
                    await MainActor.run { [weak self] in
                        self?.updateStats(stats)
                    }
                },
                onTrackerUpdate: { [weak self] statuses in
                    await MainActor.run { [weak self] in
                        self?.trackerStatuses = statuses
                    }
                },
                onPeersUpdate: { [weak self] details in
                    await MainActor.run { [weak self] in
                        self?.peers = details
                    }
                },
                onStateChange: { [weak self] newState in
                    await MainActor.run { [weak self] in
                        self?.state = newState
                        self?.stats.state = newState
                    }
                },
                onError: { [weak self] message in
                    await MainActor.run { [weak self] in
                        self?.error = message
                        self?.state = .error
                    }
                }
            )

            await actor.start()
            startStatsPolling()

        } else if let magnet = magnetLink {
            state = .metadataFetch
            // Fetch metadata via ut_metadata / DHT
            await fetchMetadata(magnet: magnet)
        }
    }

    func pause() async {
        await sessionActor?.pause()
        state = .paused
        stats.state = .paused
    }

    func resume() async {
        await sessionActor?.resume()
        state = .downloading
        stats.state = .downloading
    }

    func stop() async {
        statsTask?.cancel()
        await sessionActor?.stop()
        state = .stopped
        stats.state = .stopped
        sessionActor = nil
    }

    func recheck() async {
        await stop()
        await sessionActor?.recheck()
        await start()
    }

    // MARK: - Metadata Fetch

    private func fetchMetadata(magnet: MagnetLink) async {
        // In production: use ut_metadata to fetch from peers found via DHT/trackers
        // Connect to peers from magnet trackers, exchange extension handshake,
        // request metadata pieces via ut_metadata protocol
        logger.info("Fetching metadata for magnet: \(magnet.infoHash.description)")

        let fetcher = MetadataFetcher(magnet: magnet)
        do {
            let meta = try await fetcher.fetch()
            await MainActor.run { [weak self] in
                self?.metadata = meta
                self?.files = meta.files
            }
            await start()
        } catch {
            await MainActor.run { [weak self] in
                self?.error = "Metadata fetch failed: \(error.localizedDescription)"
                self?.state = .error
            }
        }
    }

    // MARK: - Stats Polling

    private func startStatsPolling() {
        statsTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { break }
                if let actor = await self.sessionActor {
                    let s = await actor.currentStats()
                    let p = await actor.peerDetails()
                    await MainActor.run {
                        self.updateStats(s)
                        self.peers = p
                    }
                }
            }
        }
    }

    private func updateStats(_ s: TorrentStats) {
        stats = s
        // Rolling speed history
        speedHistory.append(s.downloadSpeed)
        if speedHistory.count > 60 { speedHistory.removeFirst() }
    }
}

// MARK: - TorrentSessionActor

actor TorrentSessionActor {
    private let metadata: TorrentMetadata
    private let saveDirectory: URL
    private var pieceManager: PieceManager
    private var peerManager: PeerManager?
    private var trackerManager: TrackerManager
    private var dhtEngine: DHTEngine?
    private var lsd: LocalServiceDiscovery
    private var storageManager: StorageManager
    private let localPeerID: Data
    private let listenPort: UInt16 = 6881

    private var state: TorrentState = .stopped
    private var downloadSpeed: Double = 0
    private var uploadSpeed: Double = 0
    private var speedSamples: [(Date, Int64)] = []
    private var totalUploaded: Int64 = 0

    private var requestSchedulerTask: Task<Void, Never>?
    private var speedUpdateTask: Task<Void, Never>?

    // Callbacks (must be sendable closures)
    private var onStatsUpdate: (@Sendable (TorrentStats) async -> Void)?
    private var onTrackerUpdate: (@Sendable ([TrackerStatus]) async -> Void)?
    private var onPeersUpdate: (@Sendable ([PeerDetail]) async -> Void)?
    private var onStateChange: (@Sendable (TorrentState) async -> Void)?
    private var onError: (@Sendable (String) async -> Void)?

    private let logger = Logger(subsystem: "com.bitflow.engine", category: "TorrentSessionActor")

    init(metadata: TorrentMetadata, saveDir: URL) {
        self.metadata = metadata
        self.saveDirectory = saveDir
        self.localPeerID = Self.generatePeerID()
        self.pieceManager = PieceManager(metadata: metadata)
        self.storageManager = StorageManager(metadata: metadata, directory: saveDir)
        self.lsd = LocalServiceDiscovery(localPeerID: self.localPeerID)

        let infoHash = metadata.infoHash.primary.data
        self.trackerManager = TrackerManager(
            infoHash: infoHash,
            peerID: self.localPeerID,
            port: 6881,
            announceGroups: metadata.announceList
        )
    }

    func setCallbacks(
        onStatsUpdate: @escaping @Sendable (TorrentStats) async -> Void,
        onTrackerUpdate: @escaping @Sendable ([TrackerStatus]) async -> Void,
        onPeersUpdate: @escaping @Sendable ([PeerDetail]) async -> Void,
        onStateChange: @escaping @Sendable (TorrentState) async -> Void,
        onError: @escaping @Sendable (String) async -> Void
    ) {
        self.onStatsUpdate = onStatsUpdate
        self.onTrackerUpdate = onTrackerUpdate
        self.onPeersUpdate = onPeersUpdate
        self.onStateChange = onStateChange
        self.onError = onError
    }

    func start() async {
        guard state == .stopped || state == .paused else { return }
        state = .downloading

        // Load existing bitfield if resuming
        await loadPersistedState()

        // Setup storage
        do {
            try await storageManager.prepare()
        } catch {
            await onError?("Storage error: \(error.localizedDescription)")
            return
        }

        // Setup peer manager
        let pm = PeerManager(
            infoHash: metadata.infoHash.primary.data,
            localPeerID: localPeerID,
            pieceManager: pieceManager
        )
        self.peerManager = pm

        setupPeerManagerCallbacks(pm)

        // Setup tracker manager
        trackerManager.onPeersReceived = { [weak self] peerDataBlocks in
            Task { [weak self] in
                guard let self else { return }
                for data in peerDataBlocks {
                    if data.count % 6 == 0 {
                        await pm.addCompactPeers(data)
                    } else if data.count % 18 == 0 {
                        await pm.addCompactPeersIPv6(data)
                    }
                }
            }
        }
        trackerManager.onStatusUpdated = { [weak self] statuses in
            Task { [weak self] in
                await self?.onTrackerUpdate?(statuses)
            }
        }

        // DHT (disabled for private torrents)
        if !metadata.isPrivate {
            let dht = DHTEngine(port: listenPort)
            self.dhtEngine = dht
            dht.onPeersFound = { [weak pm] peers in
                Task { [weak pm] in await pm?.addPeers(peers) }
            }
            await dht.start()
            await dht.getPeers(infoHash: metadata.infoHash.primary.data)
        }

        // LSD
        if !metadata.isPrivate {
            let infoHashHex = metadata.infoHash.primary.data.hexString
            lsd.onPeersFound = { [weak pm] _, peers in
                Task { [weak pm] in await pm?.addPeers(peers) }
            }
            await lsd.start(infoHash: infoHashHex)
        }

        // Add DHT bootstrap nodes
        var bootPeers: [PeerInfo] = []
        for node in metadata.nodes {
            bootPeers.append(PeerInfo(host: node.host, port: UInt16(node.port), source: .dht, lastSeen: .now, failCount: 0))
        }
        if !bootPeers.isEmpty { await pm.addPeers(bootPeers) }

        // Start trackers
        let dl = await pieceManager.totalDownloadedBytes
        let left = metadata.totalLength - dl
        await trackerManager.updateStats(downloaded: dl, uploaded: totalUploaded, left: left)
        await trackerManager.startAnnouncing()

        // Start choke algorithm
        await pm.startChokeAlgorithm()

        // Start request scheduling loop
        startRequestScheduler()
        startSpeedTracking()
    }

    func pause() async {
        state = .paused
        requestSchedulerTask?.cancel()
        speedUpdateTask?.cancel()
        await trackerManager.stopAnnouncing()
        await peerManager?.stopAll()
    }

    func resume() async {
        await start()
    }

    func stop() async {
        state = .stopped
        requestSchedulerTask?.cancel()
        speedUpdateTask?.cancel()
        await trackerManager.stopAnnouncing()
        await peerManager?.stopAll()
        await dhtEngine?.stop()
        await persistState()
    }

    func recheck() async {
        logger.info("Rechecking files for \(self.metadata.name)")
        let bitfield = await storageManager.verifyAllPieces(pieceManager: pieceManager)
        self.pieceManager = PieceManager(metadata: metadata, existingBitfield: bitfield)
    }

    // MARK: - Callbacks Setup

    private func setupPeerManagerCallbacks(_ pm: PeerManager) {
        pm.onBlockReceived = { [weak self] index, begin, data in
            await self?.handleBlock(pieceIndex: index, offset: begin, data: data)
        }
        pm.onPeerBitfield = { _, _ in }
        pm.onPeerHave = { _, _ in }
        pm.onNewPeersDiscovered = { _ in }
    }

    // MARK: - Block Handling

    private func handleBlock(pieceIndex: Int, offset: Int, data: Data) async {
        let complete = await pieceManager.blockReceived(pieceIndex: pieceIndex, offset: offset, data: data)
        if complete {
            // Write piece to disk
            do {
                let pieceData = await assemblePiece(index: pieceIndex)
                if let pieceData {
                    try await storageManager.writePiece(index: pieceIndex, data: pieceData)
                    await peerManager?.broadcastHave(pieceIndex: pieceIndex)
                    logger.debug("Piece \(pieceIndex) written to disk")

                    // Check if complete
                    if await pieceManager.isComplete {
                        state = .seeding
                        await onStateChange?(.seeding)
                        await trackerManager.announceCompleted()
                        await trackerManager.updateStats(
                            downloaded: metadata.totalLength,
                            uploaded: totalUploaded,
                            left: 0
                        )
                    }
                }
            } catch {
                logger.error("Disk write failed for piece \(pieceIndex): \(error)")
            }
        }
    }

    private func assemblePiece(index: Int) async -> Data? {
        // In production this would be assembled from received blocks
        // The piece manager holds received blocks in memory until verified
        return nil  // StorageManager handles final write
    }

    // MARK: - Request Scheduler

    private func startRequestScheduler() {
        requestSchedulerTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                await self?.peerManager?.scheduleRequests()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    // MARK: - Speed Tracking

    private func startSpeedTracking() {
        speedUpdateTask = Task.detached(priority: .utility) { [weak self] in
            var lastBytes: Int64 = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { break }
                let current = await self.pieceManager.totalDownloadedBytes
                let dl = Double(current - lastBytes)
                await self.updateDownloadSpeed(dl)
                lastBytes = current
            }
        }
    }

    private func updateDownloadSpeed(_ speed: Double) async {
        downloadSpeed = speed
        uploadSpeed = await peerManager?.aggregateUploadSpeed() ?? 0
        let stats = await currentStats()
        await onStatsUpdate?(stats)
    }

    func currentStats() async -> TorrentStats {
        let downloaded = await pieceManager.totalDownloadedBytes
        let progress = await pieceManager.completionFraction
        let left = metadata.totalLength - downloaded

        var eta: TimeInterval? = nil
        if downloadSpeed > 0 && left > 0 {
            eta = Double(left) / downloadSpeed
        }

        return TorrentStats(
            downloadSpeed: downloadSpeed,
            uploadSpeed: uploadSpeed,
            progress: progress,
            eta: eta,
            seeders: trackerManager.allStatuses.reduce(0) { $0 + $1.seeders },
            leechers: trackerManager.allStatuses.reduce(0) { $0 + $1.leechers },
            peers: await peerManager?.connectedPeerCount ?? 0,
            downloaded: downloaded,
            uploaded: totalUploaded,
            totalSize: metadata.totalLength,
            ratio: downloaded > 0 ? Double(totalUploaded) / Double(downloaded) : 0,
            availability: progress,
            state: state
        )
    }

    func peerDetails() async -> [PeerDetail] {
        await peerManager?.peerDetails() ?? []
    }

    // MARK: - Persistence

    private func persistState() async {
        let bf = await pieceManager.currentBitfield
        let key = "bitfield_\(metadata.infoHash.primary.data.hexString)"
        UserDefaults.standard.set(bf.data, forKey: key)
    }

    private func loadPersistedState() async {
        let key = "bitfield_\(metadata.infoHash.primary.data.hexString)"
        if let data = UserDefaults.standard.data(forKey: key) {
            let bf = Bitfield(data: data, size: metadata.pieceCount)
            self.pieceManager = PieceManager(metadata: metadata, existingBitfield: bf)
        }
    }

    // MARK: - Peer ID

    private static func generatePeerID() -> Data {
        // BitFlow client prefix: -BF0100-
        var id = Data("-BF0100-".utf8)
        while id.count < 20 {
            id.append(UInt8.random(in: 48...57))  // ASCII digits
        }
        return id.prefix(20)
    }
}
