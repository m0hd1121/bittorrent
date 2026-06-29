import XCTest
@testable import BitFlowCore

final class BencodeTests: XCTestCase {

    // MARK: - Decode

    func testDecodeInteger() throws {
        let data = "i42e".data(using: .utf8)!
        let value = try BencodeDecoder.decode(data)
        XCTAssertEqual(value.intValue, 42)
    }

    func testDecodeNegativeInteger() throws {
        let data = "i-17e".data(using: .utf8)!
        let value = try BencodeDecoder.decode(data)
        XCTAssertEqual(value.intValue, -17)
    }

    func testDecodeString() throws {
        let data = "5:hello".data(using: .utf8)!
        let value = try BencodeDecoder.decode(data)
        XCTAssertEqual(value.stringValue, "hello")
    }

    func testDecodeEmptyString() throws {
        let data = "0:".data(using: .utf8)!
        let value = try BencodeDecoder.decode(data)
        XCTAssertEqual(value.dataValue, Data())
    }

    func testDecodeList() throws {
        let data = "li1ei2ei3ee".data(using: .utf8)!
        let value = try BencodeDecoder.decode(data)
        let list = try XCTUnwrap(value.listValue)
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(list[0].intValue, 1)
        XCTAssertEqual(list[1].intValue, 2)
        XCTAssertEqual(list[2].intValue, 3)
    }

    func testDecodeDictionary() throws {
        let data = "d3:bar4:spam3:fooi42ee".data(using: .utf8)!
        let value = try BencodeDecoder.decode(data)
        let dict = try XCTUnwrap(value.dictValue)
        XCTAssertEqual(dict["foo"]?.intValue, 42)
        XCTAssertEqual(dict["bar"]?.stringValue, "spam")
    }

    func testDecodeNestedStructure() throws {
        let data = "d4:listli1ei2ee3:stri99ee".data(using: .utf8)!
        let value = try BencodeDecoder.decode(data)
        let dict = try XCTUnwrap(value.dictValue)
        XCTAssertEqual(dict["str"]?.intValue, 99)
        XCTAssertEqual(dict["list"]?.listValue?.count, 2)
    }

    // MARK: - Encode

    func testEncodeInteger() {
        let encoded = BencodeEncoder.encode(.integer(100))
        XCTAssertEqual(String(data: encoded, encoding: .utf8), "i100e")
    }

    func testEncodeString() {
        let encoded = BencodeEncoder.encode(.string("world".data(using: .utf8)!))
        XCTAssertEqual(String(data: encoded, encoding: .utf8), "5:world")
    }

    func testEncodeList() {
        let encoded = BencodeEncoder.encode(.list([.integer(1), .integer(2)]))
        XCTAssertEqual(String(data: encoded, encoding: .utf8), "li1ei2ee")
    }

    func testEncodeDictionaryKeysAreSorted() {
        let encoded = BencodeEncoder.encode(.dictionary([
            "z": .integer(1),
            "a": .integer(2)
        ]))
        XCTAssertEqual(String(data: encoded, encoding: .utf8), "d1:ai2e1:zi1ee")
    }

    // MARK: - Round-trip

    func testRoundTrip() throws {
        let original: BencodeValue = .dictionary([
            "name": .string("test".data(using: .utf8)!),
            "count": .integer(42),
            "items": .list([.string("a".data(using: .utf8)!), .string("b".data(using: .utf8)!)])
        ])
        let encoded = BencodeEncoder.encode(original)
        let decoded = try BencodeDecoder.decode(encoded)
        XCTAssertEqual(original, decoded)
    }

    // MARK: - Error Cases

    func testDecodeInvalidBytes() {
        let data = "x42e".data(using: .utf8)!
        XCTAssertThrowsError(try BencodeDecoder.decode(data))
    }

    func testDecodeEmptyData() {
        XCTAssertThrowsError(try BencodeDecoder.decode(Data()))
    }

    func testDecodeTruncatedInteger() {
        let data = "i42".data(using: .utf8)!
        XCTAssertThrowsError(try BencodeDecoder.decode(data))
    }
}
