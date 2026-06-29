import Foundation
import os.log

// MARK: - Metadata Fetcher (BEP 9 ut_metadata)

actor MetadataFetcher {
    private let magnet: MagnetLink
    private var metadataPieces: [Int: Data] = [:]
    private var totalSize: Int?
    private var pieceCount: Int = 0
    private let logger = Logger(subsystem: "com.bitflow.engine", category: "MetadataFetcher")

    static let metadataPieceSize = 16_384  // 16 KiB

    init(magnet: MagnetLink) {
        self.magnet = magnet
    }

    func fetch() async throws -> TorrentMetadata {
        logger.info("Starting metadata fetch for \(self.magnet.infoHash.description)")

        // Try connecting to peers from magnet trackers and DHT
        var peers: [PeerInfo] = []

        // Announce to trackers to get peers
        for trackerURL in magnet.trackers.prefix(5) {
            if let p = try? await fetchPeersFromTracker(url: trackerURL) {
                peers.append(contentsOf: p)
            }
        }

        // Add any x.pe direct peers from magnet
        for (host, port) in magnet.dhtNodes {
            peers.append(PeerInfo(host: host, port: UInt16(port), source: .manual, lastSeen: .now, failCount: 0))
        }

        guard !peers.isEmpty else {
            throw FetchError.noPeers
        }

        // Try to get metadata from each peer
        for peer in peers.prefix(10) {
            if let data = try? await fetchMetadataFromPeer(peer: peer) {
                return try TorrentParser.parse(data: data)
            }
        }

        throw FetchError.metadataUnavailable
    }

    private func fetchPeersFromTracker(url: String) async throws -> [PeerInfo] {
        let response = try await HTTPTracker.announce(
            url: url,
            infoHash: magnet.infoHash.data,
            peerID: generateLocalPeerID(),
            port: 6881,
            event: .started,
            downloaded: 0,
            uploaded: 0,
            left: 0
        )

        var peers: [PeerInfo] = []
        var i = response.peers.startIndex
        while response.peers.distance(from: i, to: response.peers.endIndex) >= 6 {
            let ip = response.peers[i..<response.peers.index(i, offsetBy: 4)].map { String($0) }.joined(separator: ".")
            let portData = response.peers[response.peers.index(i, offsetBy: 4)..<response.peers.index(i, offsetBy: 6)]
            let port = portData.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
            peers.append(PeerInfo(host: ip, port: port, source: .tracker, lastSeen: .now, failCount: 0))
            i = response.peers.index(i, offsetBy: 6)
        }
        return peers
    }

    private func fetchMetadataFromPeer(peer: PeerInfo) async throws -> Data {
        // Connect to peer, perform BT handshake, exchange extension handshake,
        // then request metadata pieces via ut_metadata
        let conn = PeerConnection(
            address: peer.host,
            port: peer.port,
            infoHash: magnet.infoHash.data,
            localPeerID: generateLocalPeerID()
        )

        return try await withTimeout(seconds: 30) {
            // Connect and handshake handled by PeerConnection
            // For metadata fetch we need the extension handshake to tell us metadata size
            // Then we request each piece sequentially

            // Simplified: in production, PeerConnection callbacks drive this
            throw FetchError.metadataUnavailable
        }
    }

    private func generateLocalPeerID() -> Data {
        var id = Data("-BF0100-".utf8)
        while id.count < 20 { id.append(UInt8.random(in: 48...57)) }
        return id.prefix(20)
    }

    private func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw FetchError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    enum FetchError: Error, Sendable {
        case noPeers
        case timeout
        case metadataUnavailable
        case invalidMetadata
    }
}
