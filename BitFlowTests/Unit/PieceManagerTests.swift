import XCTest
import CryptoKit
@testable import BitFlowCore

final class PieceManagerTests: XCTestCase {

    // Build a minimal TorrentMetadata for tests
    private func makeMetadata(pieceCount: Int, pieceLength: Int64 = 262144) throws -> TorrentMetadata {
        // Generate random pieces with known SHA1
        var pieces: [Data] = []
        for _ in 0..<pieceCount {
            pieces.append(Data(Insecure.SHA1.hash(data: Data(repeating: 0, count: Int(pieceLength)))))
        }
        let totalLength = Int64(pieceCount) * pieceLength
        let infoHash = try InfoHash(v1: Data(repeating: 0xAB, count: 20))

        return TorrentMetadata(
            infoHash: HybridInfoHash(v1: infoHash),
            name: "Test",
            pieceLength: pieceLength,
            pieces: pieces,
            pieceLayersV2: nil,
            files: [TorrentFileEntry(path: ["test.bin"], length: totalLength)],
            totalLength: totalLength,
            announceList: [],
            webSeeds: [],
            nodes: [],
            comment: nil,
            createdBy: nil,
            creationDate: nil,
            isPrivate: false,
            version: .v1
        )
    }

    func testInitialCompletionIsZero() async throws {
        let meta = try makeMetadata(pieceCount: 10)
        let pm = PieceManager(metadata: meta)
        let fraction = await pm.completionFraction
        XCTAssertEqual(fraction, 0.0)
    }

    func testExistingBitfieldRestoresProgress() async throws {
        let meta = try makeMetadata(pieceCount: 10)
        var bf = Bitfield(size: 10)
        bf[0] = true
        bf[1] = true
        bf[2] = true
        let pm = PieceManager(metadata: meta, existingBitfield: bf)
        let fraction = await pm.completionFraction
        XCTAssertEqual(fraction, 0.3, accuracy: 0.01)
    }

    func testPieceAvailabilityUpdatesOnBitfield() async throws {
        let meta = try makeMetadata(pieceCount: 5)
        let pm = PieceManager(metadata: meta)

        var peerBf = Bitfield(size: 5)
        peerBf[0] = true
        peerBf[2] = true
        await pm.setPeerBitfield(peerBf, for: "peer1")

        // Peer should have pieces 0 and 2 available for requests
        let requests = await pm.nextBlocks(for: "peer1", count: 2, endGame: false)
        XCTAssertFalse(requests.isEmpty)
    }

    func testRemovePeerUpdatesAvailability() async throws {
        let meta = try makeMetadata(pieceCount: 5)
        let pm = PieceManager(metadata: meta)
        var peerBf = Bitfield(size: 5)
        for i in 0..<5 { peerBf[i] = true }
        await pm.setPeerBitfield(peerBf, for: "peer1")
        await pm.removePeer("peer1")

        // After removal, peer should have no pieces
        let requests = await pm.nextBlocks(for: "peer1", count: 10, endGame: false)
        XCTAssertTrue(requests.isEmpty)
    }

    func testPieceVerificationSuccess() async throws {
        let pieceLength: Int64 = 32768
        let pieceData = Data(repeating: 0, count: Int(pieceLength))
        let correctHash = Data(Insecure.SHA1.hash(data: pieceData))

        let infoHash = try InfoHash(v1: Data(repeating: 0xAB, count: 20))
        let meta = TorrentMetadata(
            infoHash: HybridInfoHash(v1: infoHash),
            name: "Test",
            pieceLength: pieceLength,
            pieces: [correctHash],
            pieceLayersV2: nil,
            files: [TorrentFileEntry(path: ["test.bin"], length: pieceLength)],
            totalLength: pieceLength,
            announceList: [],
            webSeeds: [],
            nodes: [],
            comment: nil,
            createdBy: nil,
            creationDate: nil,
            isPrivate: false,
            version: .v1
        )
        let pm = PieceManager(metadata: meta)

        // Send the single block for piece 0
        let complete = await pm.blockReceived(pieceIndex: 0, offset: 0, data: pieceData)
        XCTAssertTrue(complete)
        let fraction = await pm.completionFraction
        XCTAssertEqual(fraction, 1.0, accuracy: 0.001)
    }

    func testPieceVerificationFailure() async throws {
        let pieceLength: Int64 = 32768
        let wrongHash = Data(repeating: 0xFF, count: 20)  // Wrong hash

        let infoHash = try InfoHash(v1: Data(repeating: 0xAB, count: 20))
        let meta = TorrentMetadata(
            infoHash: HybridInfoHash(v1: infoHash),
            name: "Test",
            pieceLength: pieceLength,
            pieces: [wrongHash],
            pieceLayersV2: nil,
            files: [TorrentFileEntry(path: ["test.bin"], length: pieceLength)],
            totalLength: pieceLength,
            announceList: [],
            webSeeds: [],
            nodes: [],
            comment: nil,
            createdBy: nil,
            creationDate: nil,
            isPrivate: false,
            version: .v1
        )
        let pm = PieceManager(metadata: meta)
        let complete = await pm.blockReceived(pieceIndex: 0, offset: 0, data: Data(repeating: 0, count: Int(pieceLength)))
        XCTAssertFalse(complete)
    }

    func testEndgameModeDetection() async throws {
        let count = 100
        let meta = try makeMetadata(pieceCount: count)
        var bf = Bitfield(size: count)
        // Complete 96/100 pieces = 96%
        for i in 0..<96 { bf[i] = true }
        let pm = PieceManager(metadata: meta, existingBitfield: bf)
        let isEndgame = await pm.isEndgame()
        XCTAssertTrue(isEndgame)
    }

    func testNotEndgameAtLowProgress() async throws {
        let count = 100
        let meta = try makeMetadata(pieceCount: count)
        let pm = PieceManager(metadata: meta)
        let isEndgame = await pm.isEndgame()
        XCTAssertFalse(isEndgame)
    }
}
