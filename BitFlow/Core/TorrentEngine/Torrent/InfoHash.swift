import Foundation
import CryptoKit

// MARK: - InfoHash

struct InfoHash: Hashable, Sendable, CustomStringConvertible {
    enum Version: Sendable {
        case v1  // SHA1, 20 bytes
        case v2  // SHA256 truncated to 32 bytes
    }

    let data: Data
    let version: Version

    var description: String { data.hexString }

    init(v1 data: Data) throws {
        guard data.count == 20 else {
            throw InfoHashError.invalidLength(data.count, expected: 20)
        }
        self.data = data
        self.version = .v1
    }

    init(v2 data: Data) throws {
        guard data.count == 32 else {
            throw InfoHashError.invalidLength(data.count, expected: 32)
        }
        self.data = data
        self.version = .v2
    }

    static func from(infoDict: BencodeValue) throws -> InfoHash {
        let encoded = BencodeEncoder.encode(infoDict)
        let hash = Data(Insecure.SHA1.hash(data: encoded))
        return try InfoHash(v1: hash)
    }

    static func v2From(infoDict: BencodeValue) throws -> InfoHash {
        let encoded = BencodeEncoder.encode(infoDict)
        let hash = Data(SHA256.hash(data: encoded))
        return try InfoHash(v2: hash)
    }

    enum InfoHashError: Error, Sendable {
        case invalidLength(Int, expected: Int)
    }
}

// MARK: - HybridInfoHash (v1 + v2 for hybrid torrents)

struct HybridInfoHash: Sendable {
    let v1: InfoHash?
    let v2: InfoHash?

    var primary: InfoHash {
        v2 ?? v1!
    }

    init(v1: InfoHash? = nil, v2: InfoHash? = nil) {
        self.v1 = v1
        self.v2 = v2
    }
}

// MARK: - Data Extension

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hexString: String) {
        let hex = hexString
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            bytes.append(byte)
            idx = next
        }
        self.init(bytes)
    }
}
