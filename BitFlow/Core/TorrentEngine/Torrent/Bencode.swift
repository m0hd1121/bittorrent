import Foundation

// MARK: - Bencode Value

indirect enum BencodeValue: Sendable, Equatable {
    case string(Data)
    case integer(Int64)
    case list([BencodeValue])
    case dictionary([String: BencodeValue])

    var stringValue: String? {
        guard case .string(let data) = self else { return nil }
        return String(data: data, encoding: .utf8)
    }

    var dataValue: Data? {
        guard case .string(let data) = self else { return nil }
        return data
    }

    var intValue: Int64? {
        guard case .integer(let v) = self else { return nil }
        return v
    }

    var listValue: [BencodeValue]? {
        guard case .list(let v) = self else { return nil }
        return v
    }

    var dictValue: [String: BencodeValue]? {
        guard case .dictionary(let v) = self else { return nil }
        return v
    }

    subscript(key: String) -> BencodeValue? {
        dictValue?[key]
    }
}

// MARK: - Decoder

enum BencodeDecoder {
    enum DecodeError: Error, Sendable {
        case invalidData
        case unexpectedEnd
        case invalidInteger
        case invalidString
        case invalidFormat(String)
    }

    static func decode(_ data: Data) throws -> BencodeValue {
        var index = data.startIndex
        let value = try decodeValue(data: data, index: &index)
        return value
    }

    private static func decodeValue(data: Data, index: inout Data.Index) throws -> BencodeValue {
        guard index < data.endIndex else { throw DecodeError.unexpectedEnd }
        let byte = data[index]

        switch byte {
        case UInt8(ascii: "i"):
            return try decodeInteger(data: data, index: &index)
        case UInt8(ascii: "l"):
            return try decodeList(data: data, index: &index)
        case UInt8(ascii: "d"):
            return try decodeDictionary(data: data, index: &index)
        case UInt8(ascii: "0") ... UInt8(ascii: "9"):
            return try decodeString(data: data, index: &index)
        default:
            throw DecodeError.invalidFormat("Unexpected byte: \(byte)")
        }
    }

    private static func decodeInteger(data: Data, index: inout Data.Index) throws -> BencodeValue {
        index = data.index(after: index) // skip 'i'
        var numStr = ""
        while index < data.endIndex && data[index] != UInt8(ascii: "e") {
            numStr.append(Character(UnicodeScalar(data[index])))
            index = data.index(after: index)
        }
        guard index < data.endIndex else { throw DecodeError.unexpectedEnd }
        index = data.index(after: index) // skip 'e'
        guard let num = Int64(numStr) else { throw DecodeError.invalidInteger }
        return .integer(num)
    }

    private static func decodeString(data: Data, index: inout Data.Index) throws -> BencodeValue {
        var lenStr = ""
        while index < data.endIndex && data[index] != UInt8(ascii: ":") {
            lenStr.append(Character(UnicodeScalar(data[index])))
            index = data.index(after: index)
        }
        guard index < data.endIndex else { throw DecodeError.unexpectedEnd }
        index = data.index(after: index) // skip ':'
        guard let length = Int(lenStr), length >= 0 else { throw DecodeError.invalidString }
        let end = data.index(index, offsetBy: length, limitedBy: data.endIndex) ?? data.endIndex
        guard data.distance(from: index, to: end) == length else { throw DecodeError.unexpectedEnd }
        let strData = data[index..<end]
        index = end
        return .string(Data(strData))
    }

    private static func decodeList(data: Data, index: inout Data.Index) throws -> BencodeValue {
        index = data.index(after: index) // skip 'l'
        var list: [BencodeValue] = []
        while index < data.endIndex && data[index] != UInt8(ascii: "e") {
            list.append(try decodeValue(data: data, index: &index))
        }
        guard index < data.endIndex else { throw DecodeError.unexpectedEnd }
        index = data.index(after: index) // skip 'e'
        return .list(list)
    }

    private static func decodeDictionary(data: Data, index: inout Data.Index) throws -> BencodeValue {
        index = data.index(after: index) // skip 'd'
        var dict: [String: BencodeValue] = [:]
        while index < data.endIndex && data[index] != UInt8(ascii: "e") {
            guard case .string(let keyData) = try decodeString(data: data, index: &index),
                  let key = String(data: keyData, encoding: .utf8) else {
                throw DecodeError.invalidFormat("Dictionary key must be a UTF-8 string")
            }
            let value = try decodeValue(data: data, index: &index)
            dict[key] = value
        }
        guard index < data.endIndex else { throw DecodeError.unexpectedEnd }
        index = data.index(after: index) // skip 'e'
        return .dictionary(dict)
    }
}

// MARK: - Encoder

enum BencodeEncoder {
    static func encode(_ value: BencodeValue) -> Data {
        var result = Data()
        encode(value, into: &result)
        return result
    }

    private static func encode(_ value: BencodeValue, into data: inout Data) {
        switch value {
        case .string(let bytes):
            data.append(contentsOf: "\(bytes.count):".utf8)
            data.append(bytes)
        case .integer(let i):
            data.append(contentsOf: "i\(i)e".utf8)
        case .list(let list):
            data.append(UInt8(ascii: "l"))
            for item in list { encode(item, into: &data) }
            data.append(UInt8(ascii: "e"))
        case .dictionary(let dict):
            data.append(UInt8(ascii: "d"))
            for key in dict.keys.sorted() {
                let keyData = key.data(using: .utf8) ?? Data()
                data.append(contentsOf: "\(keyData.count):".utf8)
                data.append(keyData)
                encode(dict[key]!, into: &data)
            }
            data.append(UInt8(ascii: "e"))
        }
    }
}
