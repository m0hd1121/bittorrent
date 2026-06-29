import Foundation
import Network
import os.log

// MARK: - Peer Info

struct PeerInfo: Sendable, Hashable {
    let host: String
    let port: UInt16
    var source: PeerSource
    var lastSeen: Date
    var failCount: Int

    var id: String { "\(host):\(port)" }

    enum PeerSource: Sendable {
        case tracker, dht, pex, lsd, manual
    }
}

// MARK: - Choke Algorithm Result

struct ChokeDecision: Sendable {
    let peerID: String
    let shouldChoke: Bool
}

// MARK: - Peer Manager

actor PeerManager {
    private let infoHash: Data
    private let localPeerID: Data
    private var connections: [String: PeerConnection] = [:]
    private var knownPeers: [String: PeerInfo] = [:]
    private var pieceManager: PeerManager.PieceManagerRef

    private let maxConnections: Int
    private let maxHalfOpen: Int = 30
    private var halfOpenCount = 0
    private var connectTasks: [String: Task<Void, Never>] = [:]

    private let logger = Logger(subsystem: "com.bitflow.engine", category: "PeerManager")

    // Choking state
    private var unchokedPeers: Set<String> = []
    private var optimisticUnchoke: String?
    private var chokeTimer: Task<Void, Never>?

    // Upload slots (BT standard: 4 + optimistic)
    private let uploadSlots = 4

    // Scoring
    private var peerScores: [String: Double] = [:]

    // Callbacks to torrent session
    var onBlockReceived: (@Sendable (Int, Int, Data) async -> Void)?
    var onPeerBitfield: (@Sendable (String, Bitfield) -> Void)?
    var onPeerHave: (@Sendable (String, Int) -> Void)?
    var onNewPeersDiscovered: (@Sendable ([PeerInfo]) -> Void)?
    var onDHTPortReceived: (@Sendable (String, UInt16) -> Void)?

    typealias PieceManagerRef = PieceManager

    init(infoHash: Data, localPeerID: Data, pieceManager: PieceManager, maxConnections: Int = 100) {
        self.infoHash = infoHash
        self.localPeerID = localPeerID
        self.pieceManager = pieceManager
        self.maxConnections = maxConnections
    }

    // MARK: - Add Peers

    func addPeers(_ peers: [PeerInfo]) {
        for peer in peers {
            knownPeers[peer.id] = peer
        }
        Task { await fillConnections() }
    }

    func addCompactPeers(_ data: Data) {
        var peers: [PeerInfo] = []
        var i = data.startIndex
        while data.distance(from: i, to: data.endIndex) >= 6 {
            let ipBytes = data[i..<data.index(i, offsetBy: 4)]
            let portBytes = data[data.index(i, offsetBy: 4)..<data.index(i, offsetBy: 6)]
            let ip = ipBytes.map { String($0) }.joined(separator: ".")
            let port = portBytes.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
            peers.append(PeerInfo(host: ip, port: port, source: .tracker, lastSeen: .now, failCount: 0))
            i = data.index(i, offsetBy: 6)
        }
        addPeers(peers)
    }

    func addCompactPeersIPv6(_ data: Data) {
        var peers: [PeerInfo] = []
        var i = data.startIndex
        while data.distance(from: i, to: data.endIndex) >= 18 {
            let ipBytes = data[i..<data.index(i, offsetBy: 16)]
            let portBytes = data[data.index(i, offsetBy: 16)..<data.index(i, offsetBy: 18)]
            let port = portBytes.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
            let ip = formatIPv6(ipBytes)
            peers.append(PeerInfo(host: ip, port: port, source: .tracker, lastSeen: .now, failCount: 0))
            i = data.index(i, offsetBy: 18)
        }
        addPeers(peers)
    }

    private func formatIPv6(_ data: Data) -> String {
        let groups = stride(from: 0, to: 16, by: 2).map { i -> String in
            let b1 = data[data.index(data.startIndex, offsetBy: i)]
            let b2 = data[data.index(data.startIndex, offsetBy: i + 1)]
            return String(format: "%02x%02x", b1, b2)
        }
        return groups.joined(separator: ":")
    }

    // MARK: - Connection Management

    private func fillConnections() async {
        let needed = maxConnections - connections.count - halfOpenCount
        guard needed > 0 else { return }

        let candidates = knownPeers.values
            .filter { connections[$0.id] == nil && $0.failCount < 3 }
            .sorted { $0.failCount < $1.failCount }
            .prefix(min(needed, maxHalfOpen - halfOpenCount))

        for peer in candidates {
            await connect(to: peer)
        }
    }

    private func connect(to peer: PeerInfo) async {
        guard connections[peer.id] == nil, connectTasks[peer.id] == nil else { return }
        halfOpenCount += 1

        let conn = PeerConnection(address: peer.host, port: peer.port, infoHash: infoHash, localPeerID: localPeerID)
        setupCallbacks(on: conn, peerID: peer.id)
        connections[peer.id] = conn

        let task = Task.detached(priority: .utility) { [weak self] in
            await conn.connect()
        }
        connectTasks[peer.id] = task

        Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            await self?.handleConnectTimeout(peerID: peer.id)
        }
    }

    private func handleConnectTimeout(peerID: String) {
        guard let conn = connections[peerID], !conn.isActive else { return }
        logger.debug("Connection timeout for \(peerID)")
        disconnectPeer(peerID)
    }

    private func disconnectPeer(_ peerID: String) {
        connectTasks[peerID]?.cancel()
        connectTasks[peerID] = nil
        if let conn = connections[peerID] {
            Task { await conn.disconnect() }
            connections.removeValue(forKey: peerID)
        }
        halfOpenCount = max(0, halfOpenCount - 1)
        knownPeers[peerID]?.failCount += 1
        Task { await pieceManager.removePeer(peerID) }
        Task { await fillConnections() }
    }

    // MARK: - Callbacks Setup

    private func setupCallbacks(on conn: PeerConnection, peerID: String) {
        conn.onPieceReceived = { [weak self] index, begin, data in
            await self?.onBlockReceived?(index, begin, data)
        }

        conn.onBitfieldReceived = { [weak self] bitfield in
            Task { [weak self] in
                await self?.pieceManager.setPeerBitfield(bitfield, for: peerID)
            }
            self?.onPeerBitfield?(peerID, bitfield)
        }

        conn.onHaveReceived = { [weak self] index in
            Task { [weak self] in
                await self?.pieceManager.peerHasPiece(index, peer: peerID)
            }
            self?.onPeerHave?(peerID, index)
        }

        conn.onDisconnected = { [weak self] id in
            Task { [weak self] in
                await self?.handleDisconnect(peerID: id)
            }
        }

        conn.onPEXReceived = { [weak self] peers in
            let peerInfos = peers.compactMap { p -> PeerInfo? in
                guard p.address.count == 6 else { return nil }
                let ip = p.address[..<p.address.index(p.address.startIndex, offsetBy: 4)].map { String($0) }.joined(separator: ".")
                let portData = p.address[p.address.index(p.address.startIndex, offsetBy: 4)...]
                let port = portData.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
                return PeerInfo(host: ip, port: port, source: .pex, lastSeen: .now, failCount: 0)
            }
            self?.onNewPeersDiscovered?(peerInfos)
            Task { [weak self] in
                await self?.addPeers(peerInfos)
            }
        }

        conn.onPortReceived = { [weak self] dhtPort in
            self?.onDHTPortReceived?(peerID, dhtPort)
        }
    }

    private func handleDisconnect(peerID: String) {
        connections.removeValue(forKey: peerID)
        halfOpenCount = max(0, halfOpenCount - 1)
        unchokedPeers.remove(peerID)
        peerScores.removeValue(forKey: peerID)
        Task { await fillConnections() }
    }

    // MARK: - Request Scheduling

    func scheduleRequests() async {
        let endGame = await pieceManager.isEndgame()

        for (peerID, conn) in connections where await conn.canRequest {
            let capacity = await conn.hasCapacity ? 16 - conn.inflightCount : 0
            guard capacity > 0 else { continue }

            let requests = await pieceManager.nextBlocks(for: peerID, count: capacity, endGame: endGame)
            for req in requests {
                await conn.requestBlock(req)
                await pieceManager.markBlockInFlight(pieceIndex: req.pieceIndex, offset: req.blockOffset)
            }
        }
    }

    // MARK: - Choking Algorithm (BT standard tit-for-tat)

    func startChokeAlgorithm() {
        chokeTimer = Task.detached(priority: .utility) { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                tick += 1
                await self?.runChokeAlgorithm(optimistic: tick % 3 == 0)
            }
        }
    }

    private func runChokeAlgorithm(optimistic: Bool) async {
        // Score peers by download speed
        var scored: [(String, Double)] = []
        for (id, conn) in connections {
            let speed = await conn.downloadSpeed
            peerScores[id] = speed
            scored.append((id, speed))
        }
        scored.sort { $0.1 > $1.1 }

        // Unchoke top N uploaders
        var newUnchoked = Set(scored.prefix(uploadSlots).map { $0.0 })

        // Optimistic unchoke
        if optimistic {
            let chokedInterested = connections.keys
                .filter { !newUnchoked.contains($0) }
                .filter { peerScores[$0] != nil }
            if let pick = chokedInterested.randomElement() {
                optimisticUnchoke = pick
                newUnchoked.insert(pick)
            }
        } else if let opt = optimisticUnchoke {
            newUnchoked.insert(opt)
        }

        // Apply decisions
        for (id, conn) in connections {
            let shouldChoke = !newUnchoked.contains(id)
            let wasChoked = !unchokedPeers.contains(id)
            if shouldChoke && !wasChoked {
                await conn.sendChoke()
            } else if !shouldChoke && wasChoked {
                await conn.sendUnchoke()
            }
        }
        unchokedPeers = newUnchoked
    }

    // MARK: - Announce

    func announceBitfield() async {
        let bf = await pieceManager.currentBitfield
        for conn in connections.values {
            await conn.sendBitfield(bf)
        }
    }

    func broadcastHave(pieceIndex: Int) async {
        for conn in connections.values where await conn.isActive {
            await conn.sendHave(pieceIndex: pieceIndex)
        }
    }

    // MARK: - Stats

    var connectedPeerCount: Int { connections.count }

    func aggregateDownloadSpeed() async -> Double {
        var total: Double = 0
        for conn in connections.values {
            total += await conn.downloadSpeed
        }
        return total
    }

    func aggregateUploadSpeed() async -> Double {
        var total: Double = 0
        for conn in connections.values {
            total += await conn.uploadSpeed
        }
        return total
    }

    func peerDetails() async -> [PeerDetail] {
        var details: [PeerDetail] = []
        for (id, conn) in connections {
            details.append(PeerDetail(
                id: id,
                downloadSpeed: await conn.downloadSpeed,
                uploadSpeed: await conn.uploadSpeed,
                isChoked: await conn.isChoked,
                isInterested: await conn.isInterested
            ))
        }
        return details
    }

    func stopAll() async {
        chokeTimer?.cancel()
        for conn in connections.values { await conn.disconnect() }
        connections.removeAll()
        connectTasks.values.forEach { $0.cancel() }
        connectTasks.removeAll()
    }
}

// MARK: - PeerDetail

struct PeerDetail: Sendable, Identifiable {
    let id: String
    let downloadSpeed: Double
    let uploadSpeed: Double
    let isChoked: Bool
    let isInterested: Bool
}
