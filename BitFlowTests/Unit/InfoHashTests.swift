import XCTest
import CryptoKit
@testable import BitFlowCore

final class InfoHashTests: XCTestCase {

    func testV1InfoHashLength() throws {
        let data = Data(repeating: 0xAB, count: 20)
        let hash = try InfoHash(v1: data)
        XCTAssertEqual(hash.data.count, 20)
        XCTAssertEqual(hash.version, .v1)
    }

    func testV2InfoHashLength() throws {
        let data = Data(repeating: 0xCD, count: 32)
        let hash = try InfoHash(v2: data)
        XCTAssertEqual(hash.data.count, 32)
        XCTAssertEqual(hash.version, .v2)
    }

    func testV1InvalidLength() {
        XCTAssertThrowsError(try InfoHash(v1: Data(repeating: 0, count: 19)))
        XCTAssertThrowsError(try InfoHash(v1: Data(repeating: 0, count: 21)))
    }

    func testV2InvalidLength() {
        XCTAssertThrowsError(try InfoHash(v2: Data(repeating: 0, count: 31)))
    }

    func testHexString() throws {
        let bytes: [UInt8] = Array(0..<20)
        let hash = try InfoHash(v1: Data(bytes))
        XCTAssertEqual(hash.description, "000102030405060708090a0b0c0d0e0f10111213")
    }

    func testHashFromInfoDict() throws {
        // Create a minimal info dict
        let infoDict: BencodeValue = .dictionary([
            "name": .string("test.txt".data(using: .utf8)!),
            "piece length": .integer(262144),
            "pieces": .string(Data(repeating: 0, count: 20)),
            "length": .integer(1024)
        ])
        let hash = try InfoHash.from(infoDict: infoDict)
        XCTAssertEqual(hash.data.count, 20)
        XCTAssertEqual(hash.version, .v1)

        // Known SHA1 of the encoded dict — verify it's deterministic
        let hash2 = try InfoHash.from(infoDict: infoDict)
        XCTAssertEqual(hash.data, hash2.data)
    }

    func testDataHexStringConversion() {
        let data = Data([0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertEqual(data.hexString, "deadbeef")
        XCTAssertEqual(Data(hexString: "deadbeef"), data)
    }

    func testDataHexStringRoundTrip() {
        let original = Data((0..<20).map { UInt8($0) })
        let hex = original.hexString
        let restored = Data(hexString: hex)
        XCTAssertEqual(restored, original)
    }
}
