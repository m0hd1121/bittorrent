import Foundation

// MARK: - BitTorrent Wire Protocol Messages

enum PeerMessage: Sendable {
    case keepAlive
    case choke
    case unchoke
    case interested
    case notInterested
    case have(pieceIndex: Int)
    case bitfield(data: Data)
    case request(index: Int, begin: Int, length: Int)
    case piece(index: Int, begin: Int, block: Data)
    case cancel(index: Int, begin: Int, length: Int)
    case port(port: UInt16)

    // Extension protocol (BEP 10)
    case extended(id: UInt8, payload: Data)

    // MARK: - Message IDs
    enum MessageID: UInt8 {
        case choke          = 0
        case unchoke        = 1
        case interested     = 2
        case notInterested  = 3
        case have           = 4
        case bitfield       = 5
        case request        = 6
        case piece          = 7
        case cancel         = 8
        case port           = 9
        case extended       = 20
    }

    // MARK: - Serialization

    func encode() -> Data {
        switch self {
        case .keepAlive:
            return Data([0, 0, 0, 0])

        case .choke:
            return Self.fixed(id: .choke)
        case .unchoke:
            return Self.fixed(id: .unchoke)
        case .interested:
            return Self.fixed(id: .interested)
        case .notInterested:
            return Self.fixed(id: .notInterested)

        case .have(let index):
            var data = Data(capacity: 9)
            data.append(bigEndian: UInt32(5))
            data.append(MessageID.have.rawValue)
            data.append(bigEndian: UInt32(index))
            return data

        case .bitfield(let bf):
            var data = Data(capacity: 5 + bf.count)
            data.append(bigEndian: UInt32(1 + bf.count))
            data.append(MessageID.bitfield.rawValue)
            data.append(bf)
            return data

        case .request(let index, let begin, let length):
            var data = Data(capacity: 17)
            data.append(bigEndian: UInt32(13))
            data.append(MessageID.request.rawValue)
            data.append(bigEndian: UInt32(index))
            data.append(bigEndian: UInt32(begin))
            data.append(bigEndian: UInt32(length))
            return data

        case .piece(let index, let begin, let block):
            var data = Data(capacity: 13 + block.count)
            data.append(bigEndian: UInt32(9 + block.count))
            data.append(MessageID.piece.rawValue)
            data.append(bigEndian: UInt32(index))
            data.append(bigEndian: UInt32(begin))
            data.append(block)
            return data

        case .cancel(let index, let begin, let length):
            var data = Data(capacity: 17)
            data.append(bigEndian: UInt32(13))
            data.append(MessageID.cancel.rawValue)
            data.append(bigEndian: UInt32(index))
            data.append(bigEndian: UInt32(begin))
            data.append(bigEndian: UInt32(length))
            return data

        case .port(let port):
            var data = Data(capacity: 7)
            data.append(bigEndian: UInt32(3))
            data.append(MessageID.port.rawValue)
            data.append(bigEndian: port)
            return data

        case .extended(let id, let payload):
            var data = Data(capacity: 6 + payload.count)
            data.append(bigEndian: UInt32(2 + payload.count))
            data.append(MessageID.extended.rawValue)
            data.append(id)
            data.append(payload)
            return data
        }
    }

    // MARK: - Deserialization

    enum ParseError: Error, Sendable {
        case tooShort
        case unknownMessage(UInt8)
        case malformed(String)
    }

    static func decode(length: UInt32, id: UInt8, payload: Data) throws -> PeerMessage {
        if length == 0 { return .keepAlive }

        switch id {
        case MessageID.choke.rawValue:         return .choke
        case MessageID.unchoke.rawValue:       return .unchoke
        case MessageID.interested.rawValue:    return .interested
        case MessageID.notInterested.rawValue: return .notInterested

        case MessageID.have.rawValue:
            guard payload.count >= 4 else { throw ParseError.malformed("have") }
            return .have(pieceIndex: Int(payload.readUInt32(at: 0)))

        case MessageID.bitfield.rawValue:
            return .bitfield(data: payload)

        case MessageID.request.rawValue:
            guard payload.count >= 12 else { throw ParseError.malformed("request") }
            return .request(
                index: Int(payload.readUInt32(at: 0)),
                begin: Int(payload.readUInt32(at: 4)),
                length: Int(payload.readUInt32(at: 8))
            )

        case MessageID.piece.rawValue:
            guard payload.count >= 8 else { throw ParseError.malformed("piece") }
            let index = Int(payload.readUInt32(at: 0))
            let begin = Int(payload.readUInt32(at: 4))
            let block = payload.dropFirst(8)
            return .piece(index: index, begin: begin, block: Data(block))

        case MessageID.cancel.rawValue:
            guard payload.count >= 12 else { throw ParseError.malformed("cancel") }
            return .cancel(
                index: Int(payload.readUInt32(at: 0)),
                begin: Int(payload.readUInt32(at: 4)),
                length: Int(payload.readUInt32(at: 8))
            )

        case MessageID.port.rawValue:
            guard payload.count >= 2 else { throw ParseError.malformed("port") }
            return .port(port: payload.readUInt16(at: 0))

        case MessageID.extended.rawValue:
            guard !payload.isEmpty else { throw ParseError.malformed("extended") }
            return .extended(id: payload[payload.startIndex], payload: Data(payload.dropFirst()))

        default:
            throw ParseError.unknownMessage(id)
        }
    }

    // MARK: - Helpers

    private static func fixed(id: MessageID) -> Data {
        var data = Data(capacity: 5)
        data.append(bigEndian: UInt32(1))
        data.append(id.rawValue)
        return data
    }
}

// MARK: - Handshake

struct Handshake: Sendable {
    static let protocolString = "BitTorrent protocol"
    static let length = 68  // 1 + 19 + 8 + 20 + 20

    let reserved: Data      // 8 bytes for extensions
    let infoHash: Data      // 20 bytes
    let peerID: Data        // 20 bytes

    // Extension bits
    var supportsExtensionProtocol: Bool {
        get { (reserved[5] & 0x10) != 0 }
    }
    var supportsDHT: Bool {
        get { (reserved[7] & 0x01) != 0 }
    }
    var supportsFast: Bool {
        get { (reserved[7] & 0x04) != 0 }
    }

    static func create(infoHash: Data, peerID: Data, supportsDHT: Bool = true, supportsExtensions: Bool = true) -> Data {
        var data = Data(capacity: length)
        data.append(UInt8(Self.protocolString.count))
        data.append(contentsOf: Self.protocolString.utf8)
        var reserved = Data(repeating: 0, count: 8)
        if supportsExtensions { reserved[5] |= 0x10 }
        if supportsDHT { reserved[7] |= 0x01 }
        data.append(reserved)
        data.append(infoHash)
        data.append(peerID)
        return data
    }

    static func parse(_ data: Data) throws -> Handshake {
        guard data.count >= length else { throw ParseError.tooShort }
        let protoLen = Int(data[0])
        guard protoLen == 19,
              String(data: data[1...19], encoding: .utf8) == protocolString else {
            throw ParseError.invalidProtocol
        }
        let reserved = data[20..<28]
        let infoHash = data[28..<48]
        let peerID = data[48..<68]
        return Handshake(reserved: Data(reserved), infoHash: Data(infoHash), peerID: Data(peerID))
    }

    enum ParseError: Error {
        case tooShort
        case invalidProtocol
    }
}

// MARK: - Data extensions

extension Data {
    mutating func append(bigEndian value: UInt32) {
        var v = value.bigEndian
        withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func append(bigEndian value: UInt16) {
        var v = value.bigEndian
        withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    func readUInt32(at offset: Int) -> UInt32 {
        let start = index(startIndex, offsetBy: offset)
        return subdata(in: start..<index(start, offsetBy: 4)).withUnsafeBytes {
            $0.load(as: UInt32.self).bigEndian
        }
    }

    func readUInt16(at offset: Int) -> UInt16 {
        let start = index(startIndex, offsetBy: offset)
        return subdata(in: start..<index(start, offsetBy: 2)).withUnsafeBytes {
            $0.load(as: UInt16.self).bigEndian
        }
    }
}
