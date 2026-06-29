import XCTest
@testable import BitFlowCore

final class BitfieldTests: XCTestCase {

    func testEmptyBitfield() {
        let bf = Bitfield(size: 8)
        for i in 0..<8 {
            XCTAssertFalse(bf[i])
        }
    }

    func testSetBit() {
        var bf = Bitfield(size: 8)
        bf[0] = true
        XCTAssertTrue(bf[0])
        XCTAssertFalse(bf[1])
    }

    func testClearBit() {
        var bf = Bitfield(size: 8)
        bf[3] = true
        bf[3] = false
        XCTAssertFalse(bf[3])
    }

    func testBitfieldFromData() {
        // 0xFF = all 8 bits set
        let bf = Bitfield(data: Data([0xFF]), size: 8)
        for i in 0..<8 {
            XCTAssertTrue(bf[i])
        }
    }

    func testBitfieldFromPartialData() {
        // 0xA0 = 1010 0000 = bits 0 and 2 set
        let bf = Bitfield(data: Data([0xA0]), size: 8)
        XCTAssertTrue(bf[0])
        XCTAssertFalse(bf[1])
        XCTAssertTrue(bf[2])
        XCTAssertFalse(bf[3])
    }

    func testBitfieldDataRoundTrip() {
        var bf = Bitfield(size: 16)
        bf[0] = true
        bf[7] = true
        bf[8] = true
        bf[15] = true
        let data = bf.data
        let restored = Bitfield(data: data, size: 16)
        for i in 0..<16 {
            XCTAssertEqual(bf[i], restored[i], "Mismatch at bit \(i)")
        }
    }

    func testCompletedCount() {
        var bf = Bitfield(size: 10)
        XCTAssertEqual(bf.completedCount, 0)
        bf[0] = true
        bf[5] = true
        bf[9] = true
        XCTAssertEqual(bf.completedCount, 3)
    }

    func testOutOfBoundsAccess() {
        var bf = Bitfield(size: 8)
        XCTAssertFalse(bf[100])  // Should not crash, returns false
        bf[100] = true           // Should not crash
        XCTAssertFalse(bf[100]) // Still false (out of bounds write is no-op)
    }

    func testNonMultipleOf8Size() {
        var bf = Bitfield(size: 10)
        bf[9] = true
        XCTAssertTrue(bf[9])
        XCTAssertFalse(bf[8])
        XCTAssertEqual(bf.data.count, 2)  // ceil(10/8) = 2 bytes
    }

    func testAllBitsSet() {
        var bf = Bitfield(size: 8)
        for i in 0..<8 { bf[i] = true }
        XCTAssertEqual(bf.data, Data([0xFF]))
        XCTAssertEqual(bf.completedCount, 8)
    }

    func testBitOrder() {
        // BitTorrent uses MSB first: bit 0 is the leftmost bit of first byte
        var bf = Bitfield(size: 8)
        bf[0] = true  // Should set 0x80
        XCTAssertEqual(bf.data[0], 0x80)

        var bf2 = Bitfield(size: 8)
        bf2[7] = true  // Should set 0x01
        XCTAssertEqual(bf2.data[0], 0x01)
    }
}
