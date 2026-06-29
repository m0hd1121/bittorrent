import XCTest
@testable import BitFlowCore

final class PeerMessageTests: XCTestCase {

    // MARK: - Encode / Decode Round-trips

    func testKeepAlive() throws {
        let encoded = PeerMessage.keepAlive.encode()
        XCTAssertEqual(encoded, Data([0, 0, 0, 0]))
    }

    func testChoke() throws {
        let encoded = PeerMessage.choke.encode()
        XCTAssertEqual(encoded.count, 5)
        let decoded = try decodeMessage(encoded)
        guard case .choke = decoded else { XCTFail("Expected choke"); return }
    }

    func testUnchoke() throws {
        let encoded = PeerMessage.unchoke.encode()
        let decoded = try decodeMessage(encoded)
        guard case .unchoke = decoded else { XCTFail(); return }
    }

    func testInterested() throws {
        let decoded = try decodeMessage(PeerMessage.interested.encode())
        guard case .interested = decoded else { XCTFail(); return }
    }

    func testNotInterested() throws {
        let decoded = try decodeMessage(PeerMessage.notInterested.encode())
        guard case .notInterested = decoded else { XCTFail(); return }
    }

    func testHave() throws {
        let msg = PeerMessage.have(pieceIndex: 42)
        let decoded = try decodeMessage(msg.encode())
        guard case .have(let idx) = decoded else { XCTFail(); return }
        XCTAssertEqual(idx, 42)
    }

    func testBitfield() throws {
        let data = Data([0xFF, 0xAB, 0xCD])
        let msg = PeerMessage.bitfield(data: data)
        let decoded = try decodeMessage(msg.encode())
        guard case .bitfield(let d) = decoded else { XCTFail(); return }
        XCTAssertEqual(d, data)
    }

    func testRequest() throws {
        let msg = PeerMessage.request(index: 10, begin: 16384, length: 16384)
        let decoded = try decodeMessage(msg.encode())
        guard case .request(let idx, let begin, let len) = decoded else { XCTFail(); return }
        XCTAssertEqual(idx, 10)
        XCTAssertEqual(begin, 16384)
        XCTAssertEqual(len, 16384)
    }

    func testPiece() throws {
        let block = Data(repeating: 0xAB, count: 512)
        let msg = PeerMessage.piece(index: 5, begin: 0, block: block)
        let decoded = try decodeMessage(msg.encode())
        guard case .piece(let idx, let begin, let b) = decoded else { XCTFail(); return }
        XCTAssertEqual(idx, 5)
        XCTAssertEqual(begin, 0)
        XCTAssertEqual(b, block)
    }

    func testCancel() throws {
        let msg = PeerMessage.cancel(index: 1, begin: 0, length: 16384)
        let decoded = try decodeMessage(msg.encode())
        guard case .cancel(let idx, let begin, let len) = decoded else { XCTFail(); return }
        XCTAssertEqual(idx, 1)
        XCTAssertEqual(begin, 0)
        XCTAssertEqual(len, 16384)
    }

    func testPort() throws {
        let msg = PeerMessage.port(port: 6881)
        let decoded = try decodeMessage(msg.encode())
        guard case .port(let p) = decoded else { XCTFail(); return }
        XCTAssertEqual(p, 6881)
    }

    func testExtended() throws {
        let payload = Data([0x01, 0x02, 0x03])
        let msg = PeerMessage.extended(id: 1, payload: payload)
        let decoded = try decodeMessage(msg.encode())
        guard case .extended(let id, let p) = decoded else { XCTFail(); return }
        XCTAssertEqual(id, 1)
        XCTAssertEqual(p, payload)
    }

    // MARK: - Handshake

    func testHandshakeRoundTrip() throws {
        let infoHash = Data(repeating: 0xAB, count: 20)
        let peerID = Data(repeating: 0xCD, count: 20)
        let encoded = Handshake.create(infoHash: infoHash, peerID: peerID, supportsDHT: true, supportsExtensions: true)
        XCTAssertEqual(encoded.count, Handshake.length)
        let hs = try Handshake.parse(encoded)
        XCTAssertEqual(hs.infoHash, infoHash)
        XCTAssertEqual(hs.peerID, peerID)
        XCTAssertTrue(hs.supportsDHT)
        XCTAssertTrue(hs.supportsExtensionProtocol)
    }

    func testHandshakeProtocolString() throws {
        let hs = Handshake.create(infoHash: Data(repeating: 0, count: 20), peerID: Data(repeating: 0, count: 20))
        XCTAssertEqual(hs[0], 19)
        let proto = String(data: hs[1..<20], encoding: .utf8)
        XCTAssertEqual(proto, "BitTorrent protocol")
    }

    // MARK: - Helpers

    private func decodeMessage(_ data: Data) throws -> PeerMessage {
        let length = data.readUInt32(at: 0)
        if length == 0 { return .keepAlive }
        let id = data[data.index(data.startIndex, offsetBy: 4)]
        let payload = Data(data.dropFirst(5))
        return try PeerMessage.decode(length: length, id: id, payload: payload)
    }
}
