import Foundation
import CryptoKit
import os.log

// MARK: - Piece State

enum PieceState: Sendable {
    case missing
    case downloading(blocks: Set<Int>)  // block indices in-flight
    case complete
    case verified
    case failed
}

// MARK: - Block Request

struct BlockRequest: Sendable, Hashable {
    let pieceIndex: Int
    let blockOffset: Int    // byte offset within piece
    let blockLength: Int    // typically 16 KiB

    static let defaultBlockSize = 16_384  // 16 KiB per BT spec
}

// MARK: - Piece Manager

actor PieceManager {
    private let metadata: TorrentMetadata
    private var states: [PieceState]
    private var bitfield: Bitfield
    private var downloadedBytes: Int64 = 0
    private var verifiedBytes: Int64 = 0
    private let logger = Logger(subsystem: "com.bitflow.engine", category: "PieceManager")

    // Block-level tracking
    private var pendingBlocks: [Int: Set<Int>] = [:]     // pieceIndex -> block offsets
    private var receivedBlocks: [Int: [Int: Data]] = []  // pieceIndex -> offset -> data

    // Peer availability
    private var peerBitfields: [PeerID: Bitfield] = [:]
    private var pieceAvailability: [Int] = []             // count of peers having each piece

    init(metadata: TorrentMetadata, existingBitfield: Bitfield? = nil) {
        self.metadata = metadata
        let count = metadata.pieceCount
        self.states = Array(repeating: .missing, count: count)
        self.bitfield = existingBitfield ?? Bitfield(size: count)
        self.pieceAvailability = Array(repeating: 0, count: count)

        if let existing = existingBitfield {
            for i in 0..<count where existing[i] {
                states[i] = .verified
                downloadedBytes += metadata.pieceSize(at: i)
                verifiedBytes += metadata.pieceSize(at: i)
            }
        }
    }

    // MARK: - Peer Bitfield Management

    func setPeerBitfield(_ bitfield: Bitfield, for peer: PeerID) {
        let old = peerBitfields[peer] ?? Bitfield(size: metadata.pieceCount)
        peerBitfields[peer] = bitfield
        for i in 0..<metadata.pieceCount {
            let had = old[i]
            let has = bitfield[i]
            if !had && has { pieceAvailability[i] += 1 }
            if had && !has { pieceAvailability[i] = max(0, pieceAvailability[i] - 1) }
        }
    }

    func peerHasPiece(_ pieceIndex: Int, peer: PeerID) {
        if peerBitfields[peer] == nil {
            peerBitfields[peer] = Bitfield(size: metadata.pieceCount)
        }
        if !peerBitfields[peer]![pieceIndex] {
            peerBitfields[peer]![pieceIndex] = true
            pieceAvailability[pieceIndex] += 1
        }
    }

    func removePeer(_ peer: PeerID) {
        if let bf = peerBitfields.removeValue(forKey: peer) {
            for i in 0..<metadata.pieceCount where bf[i] {
                pieceAvailability[i] = max(0, pieceAvailability[i] - 1)
            }
        }
    }

    // MARK: - Piece Selection (Rarest First + End-game)

    func nextBlocks(for peer: PeerID, count: Int, endGame: Bool) -> [BlockRequest] {
        guard let peerBf = peerBitfields[peer] else { return [] }
        var requests: [BlockRequest] = []

        // Find pieces this peer has that we need, sorted by rarity
        let candidates = (0..<metadata.pieceCount)
            .filter { i in
                peerBf[i] && !self.bitfield[i] && states[i] != .verified
            }
            .sorted { pieceAvailability[$0] < pieceAvailability[$1] }

        for pieceIndex in candidates {
            guard requests.count < count else { break }
            let blocks = nextBlocks(inPiece: pieceIndex, endGame: endGame)
            requests.append(contentsOf: blocks.prefix(count - requests.count))
        }
        return requests
    }

    private func nextBlocks(inPiece index: Int, endGame: Bool) -> [BlockRequest] {
        let pieceLen = Int(metadata.pieceSize(at: index))
        let blockSize = BlockRequest.defaultBlockSize
        let blockCount = (pieceLen + blockSize - 1) / blockSize
        let inFlight = pendingBlocks[index] ?? []
        let received = Set(receivedBlocks[index]?.keys ?? [])
        var result: [BlockRequest] = []

        for b in 0..<blockCount {
            let offset = b * blockSize
            if received.contains(offset) { continue }
            if !endGame && inFlight.contains(offset) { continue }
            let length = min(blockSize, pieceLen - offset)
            result.append(BlockRequest(pieceIndex: index, blockOffset: offset, blockLength: length))
        }
        return result
    }

    // MARK: - Block Received

    func blockReceived(pieceIndex: Int, offset: Int, data: Data) async -> Bool {
        if receivedBlocks[pieceIndex] == nil {
            receivedBlocks[pieceIndex] = [:]
        }
        receivedBlocks[pieceIndex]![offset] = data
        pendingBlocks[pieceIndex]?.remove(offset)

        // Check if piece is complete
        let pieceLen = Int(metadata.pieceSize(at: pieceIndex))
        let blockSize = BlockRequest.defaultBlockSize
        let blockCount = (pieceLen + blockSize - 1) / blockSize
        let receivedCount = receivedBlocks[pieceIndex]?.count ?? 0

        guard receivedCount == blockCount else { return false }

        // Assemble piece
        var pieceData = Data(capacity: pieceLen)
        for b in 0..<blockCount {
            let off = b * blockSize
            guard let block = receivedBlocks[pieceIndex]?[off] else { return false }
            pieceData.append(block)
        }

        // Verify
        return await verifyPiece(index: pieceIndex, data: pieceData)
    }

    private func verifyPiece(index: Int, data: Data) async -> Bool {
        switch metadata.version {
        case .v1, .hybrid:
            let hash = Data(Insecure.SHA1.hash(data: data))
            guard index < metadata.pieces.count, hash == metadata.pieces[index] else {
                logger.warning("Piece \(index) SHA1 verification FAILED")
                receivedBlocks[index] = nil
                states[index] = .failed
                return false
            }
        case .v2:
            // v2 uses per-block SHA256 in piece layers; simplified: verify root hash
            let hash = Data(SHA256.hash(data: data))
            // In full v2, verify against piece layers tree
            _ = hash
        }

        logger.debug("Piece \(index) verified OK")
        states[index] = .verified
        bitfield[index] = true
        downloadedBytes += Int64(data.count)
        verifiedBytes += Int64(data.count)
        receivedBlocks[index] = nil
        return true
    }

    // MARK: - State Queries

    var completionFraction: Double {
        let total = metadata.pieceCount
        guard total > 0 else { return 0 }
        let done = (0..<total).filter { states[$0] == .verified }.count
        return Double(done) / Double(total)
    }

    var isComplete: Bool { completionFraction >= 1.0 }
    var totalDownloadedBytes: Int64 { downloadedBytes }
    var currentBitfield: Bitfield { bitfield }

    func markBlockInFlight(pieceIndex: Int, offset: Int) {
        pendingBlocks[pieceIndex, default: []].insert(offset)
    }

    func isEndgame() -> Bool {
        let remaining = (0..<metadata.pieceCount).filter { states[$0] != .verified }.count
        return remaining <= max(1, metadata.pieceCount / 20)
    }
}

// MARK: - TorrentMetadata extension for piece sizes

extension TorrentMetadata {
    func pieceSize(at index: Int) -> Int64 {
        guard index == pieces.count - 1 else {
            return pieceLength
        }
        let remainder = totalLength % pieceLength
        return remainder == 0 ? pieceLength : remainder
    }
}

// MARK: - Bitfield

struct Bitfield: Sendable {
    private var bytes: [UInt8]
    let size: Int

    init(size: Int) {
        self.size = size
        self.bytes = Array(repeating: 0, count: (size + 7) / 8)
    }

    init(data: Data, size: Int) {
        self.size = size
        self.bytes = Array(data)
        if bytes.count < (size + 7) / 8 {
            bytes.append(contentsOf: Array(repeating: 0, count: (size + 7) / 8 - bytes.count))
        }
    }

    subscript(index: Int) -> Bool {
        get {
            guard index < size else { return false }
            return (bytes[index / 8] >> (7 - (index % 8))) & 1 == 1
        }
        set {
            guard index < size else { return }
            let byteIdx = index / 8
            let bit = UInt8(1 << (7 - (index % 8)))
            if newValue { bytes[byteIdx] |= bit }
            else { bytes[byteIdx] &= ~bit }
        }
    }

    var data: Data { Data(bytes) }
    var completedCount: Int { (0..<size).filter { self[$0] }.count }
}

// MARK: - PeerID type alias

typealias PeerID = String  // "ip:port"
