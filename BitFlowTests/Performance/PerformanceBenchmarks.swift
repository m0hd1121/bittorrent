import XCTest
@testable import BitFlowCore

final class PerformanceBenchmarks: XCTestCase {

    // MARK: - Bencode

    func testBencodeDecodeLargeDict() throws {
        // Simulate a real torrent's bencode structure
        var items: [String: BencodeValue] = [:]
        for i in 0..<1000 {
            items["key\(i)"] = .string("value\(i)".data(using: .utf8)!)
        }
        let encoded = BencodeEncoder.encode(.dictionary(items))

        measure {
            for _ in 0..<100 {
                _ = try? BencodeDecoder.decode(encoded)
            }
        }
    }

    func testBencodeEncodeDecodePieces() {
        // Simulate encoding 1000 piece hashes
        let pieceHashes = (0..<1000).map { _ in Data(repeating: UInt8.random(in: 0...255), count: 20) }
        let concatenated = pieceHashes.reduce(Data()) { $0 + $1 }
        let value = BencodeValue.string(concatenated)

        measure {
            for _ in 0..<1000 {
                let encoded = BencodeEncoder.encode(value)
                _ = try? BencodeDecoder.decode(encoded)
            }
        }
    }

    // MARK: - Bitfield

    func testBitfieldLargeSetGet() {
        let size = 100_000
        var bf = Bitfield(size: size)

        measure {
            for i in 0..<size {
                bf[i] = true
            }
            for i in 0..<size {
                _ = bf[i]
            }
        }
    }

    func testBitfieldCompletedCount() {
        var bf = Bitfield(size: 50_000)
        for i in stride(from: 0, to: 50_000, by: 2) { bf[i] = true }

        measure {
            _ = bf.completedCount
        }
    }

    // MARK: - Peer Messages

    func testPeerMessageEncodeDecode() throws {
        let block = Data(repeating: 0xAB, count: 16_384)
        let msg = PeerMessage.piece(index: 100, begin: 0, block: block)

        measure {
            for _ in 0..<1000 {
                let encoded = msg.encode()
                let length = encoded.readUInt32(at: 0)
                let id = encoded[encoded.index(encoded.startIndex, offsetBy: 4)]
                let payload = Data(encoded.dropFirst(5))
                _ = try? PeerMessage.decode(length: length, id: id, payload: payload)
            }
        }
    }

    // MARK: - Data Extensions

    func testHexStringConversion() {
        let data = Data((0..<20).map { UInt8($0) })
        measure {
            for _ in 0..<10_000 {
                _ = data.hexString
            }
        }
    }
}
