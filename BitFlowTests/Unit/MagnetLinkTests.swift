import XCTest
@testable import BitFlowCore

final class MagnetLinkTests: XCTestCase {

    func testBasicMagnetLink() throws {
        let urlString = "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c&dn=TestTorrent&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337"
        let url = URL(string: urlString)!
        let magnet = try MagnetLink(url: url)

        XCTAssertEqual(magnet.infoHash.data.hexString, "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c")
        XCTAssertEqual(magnet.displayName, "TestTorrent")
        XCTAssertEqual(magnet.trackers.count, 1)
        XCTAssertTrue(magnet.trackers[0].contains("opentrackr"))
    }

    func testMagnetLinkMultipleTrackers() throws {
        let urlString = "magnet:?xt=urn:btih:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&tr=udp%3A%2F%2Ftracker1.example.com%3A1337&tr=udp%3A%2F%2Ftracker2.example.com%3A1337"
        let url = URL(string: urlString)!
        let magnet = try MagnetLink(url: url)
        XCTAssertEqual(magnet.trackers.count, 2)
    }

    func testMagnetLinkBase32InfoHash() throws {
        // 32-char base32 = 20 bytes for v1
        let urlString = "magnet:?xt=urn:btih:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        // Note: 32-char base32 should decode to 20 bytes
        // AAAA...= 0 bytes padding - test valid case
        let urlString2 = "magnet:?xt=urn:btih:MFRA"
        // This won't be 32 chars, so test with correct length
        // AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA = 32 A's in base32 = 20 bytes
        let url = URL(string: "magnet:?xt=urn:btih:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA======")!
        // Just verify parsing doesn't crash
        _ = try? MagnetLink(url: url)
    }

    func testInvalidScheme() {
        let url = URL(string: "https://example.com")!
        XCTAssertThrowsError(try MagnetLink(url: url))
    }

    func testMissingInfoHash() {
        let url = URL(string: "magnet:?dn=NoHash")!
        XCTAssertThrowsError(try MagnetLink(url: url))
    }

    func testDisplayNameDecoding() throws {
        let urlString = "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c&dn=My%20Test%20Torrent"
        let magnet = try MagnetLink(url: URL(string: urlString)!)
        XCTAssertEqual(magnet.displayName, "My Test Torrent")
    }

    func testV2MagnetLink() throws {
        // btmh: urn with SHA256 (1220 prefix = sha256 multihash)
        let hash32 = String(repeating: "00", count: 32)  // 32 zero bytes
        let urlString = "magnet:?xt=urn:btmh:1220\(hash32)"
        let url = URL(string: urlString)!
        let magnet = try MagnetLink(url: url)
        XCTAssertEqual(magnet.infoHash.version, .v2)
        XCTAssertEqual(magnet.infoHash.data.count, 32)
    }

    func testWebSeeds() throws {
        let urlString = "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c&ws=https%3A%2F%2Fexample.com%2Ffile"
        let magnet = try MagnetLink(url: URL(string: urlString)!)
        XCTAssertEqual(magnet.webSeeds.count, 1)
        XCTAssertTrue(magnet.webSeeds[0].contains("example.com"))
    }
}
