import Foundation

// BEP 10 - Extension Protocol

// MARK: - Extension Handshake

struct ExtensionHandshake: Sendable {
    var extensions: [String: Int] = [:]   // extension name -> message ID
    var clientVersion: String?
    var requestQueue: Int?                 // "reqq" - max outstanding requests
    var metadataSize: Int?                 // "metadata_size" for ut_metadata
    var yourIP: Data?                      // "yourip"
    var ipv6: Data?                        // "ipv6"
    var port: Int?                         // "p" - listen port

    static let utMetadata = "ut_metadata"
    static let utPex = "ut_pex"
    static let ltDontHave = "lt_donthave"

    func encode() -> Data {
        var dict: [String: BencodeValue] = [:]

        var mDict: [String: BencodeValue] = [:]
        for (name, id) in extensions {
            mDict[name] = .integer(Int64(id))
        }
        dict["m"] = .dictionary(mDict)

        if let v = clientVersion {
            dict["v"] = .string(v.data(using: .utf8) ?? Data())
        }
        if let rq = requestQueue {
            dict["reqq"] = .integer(Int64(rq))
        }
        if let ms = metadataSize {
            dict["metadata_size"] = .integer(Int64(ms))
        }
        if let ip = yourIP {
            dict["yourip"] = .string(ip)
        }
        if let p = port {
            dict["p"] = .integer(Int64(p))
        }

        return BencodeEncoder.encode(.dictionary(dict))
    }

    static func decode(_ data: Data) throws -> ExtensionHandshake {
        let value = try BencodeDecoder.decode(data)
        guard let dict = value.dictValue else {
            throw DecodingError.invalidFormat
        }

        var hs = ExtensionHandshake()

        if let mDict = dict["m"]?.dictValue {
            for (key, val) in mDict {
                if let id = val.intValue {
                    hs.extensions[key] = Int(id)
                }
            }
        }

        hs.clientVersion = dict["v"]?.stringValue
        hs.requestQueue = dict["reqq"].flatMap { Int($0.intValue ?? 0) }
        hs.metadataSize = dict["metadata_size"].flatMap { Int($0.intValue ?? 0) }
        hs.yourIP = dict["yourip"]?.dataValue
        hs.port = dict["p"].flatMap { Int($0.intValue ?? 0) }

        return hs
    }

    enum DecodingError: Error {
        case invalidFormat
    }
}

// MARK: - ut_metadata (BEP 9)

enum UTMetadataMessage: Sendable {
    case request(piece: Int)
    case data(piece: Int, totalSize: Int, payload: Data)
    case reject(piece: Int)

    static let msgTypeRequest = 0
    static let msgTypeData    = 1
    static let msgTypeReject  = 2

    func encode() -> Data {
        switch self {
        case .request(let piece):
            let dict: BencodeValue = .dictionary([
                "msg_type": .integer(Int64(Self.msgTypeRequest)),
                "piece": .integer(Int64(piece))
            ])
            return BencodeEncoder.encode(dict)

        case .data(let piece, let total, let payload):
            let dict: BencodeValue = .dictionary([
                "msg_type": .integer(Int64(Self.msgTypeData)),
                "piece": .integer(Int64(piece)),
                "total_size": .integer(Int64(total))
            ])
            var result = BencodeEncoder.encode(dict)
            result.append(payload)
            return result

        case .reject(let piece):
            let dict: BencodeValue = .dictionary([
                "msg_type": .integer(Int64(Self.msgTypeReject)),
                "piece": .integer(Int64(piece))
            ])
            return BencodeEncoder.encode(dict)
        }
    }

    static func decode(_ data: Data) throws -> (UTMetadataMessage, Data?) {
        // The message is bencode + optional trailing data payload
        let decoded = try BencodeDecoder.decode(data)
        guard let dict = decoded.dictValue,
              let msgType = dict["msg_type"]?.intValue,
              let piece = dict["piece"]?.intValue else {
            throw DecodeError.invalid
        }

        // Find end of bencoded part
        let encodedPart = BencodeEncoder.encode(decoded)
        let trailingOffset = encodedPart.count
        let trailing = trailingOffset < data.count ? data[data.index(data.startIndex, offsetBy: trailingOffset)...] : Data()

        switch Int(msgType) {
        case Self.msgTypeRequest:
            return (.request(piece: Int(piece)), nil)
        case Self.msgTypeData:
            let total = dict["total_size"]?.intValue ?? 0
            return (.data(piece: Int(piece), totalSize: Int(total), payload: Data(trailing)), nil)
        case Self.msgTypeReject:
            return (.reject(piece: Int(piece)), nil)
        default:
            throw DecodeError.unknown(Int(msgType))
        }
    }

    enum DecodeError: Error {
        case invalid
        case unknown(Int)
    }
}

// MARK: - PEX (ut_pex BEP 11)

struct PEXMessage: Sendable {
    struct PeerInfo: Sendable {
        let address: Data   // compact 6-byte IPv4 or 18-byte IPv6
        let flags: UInt8
    }

    let added: [PeerInfo]
    let dropped: [PeerInfo]
    let added6: [PeerInfo]
    let dropped6: [PeerInfo]

    func encode() -> Data {
        var dict: [String: BencodeValue] = [:]
        if !added.isEmpty {
            dict["added"] = .string(Data(added.flatMap { Array($0.address) }))
            dict["added.f"] = .string(Data(added.map { $0.flags }))
        }
        if !dropped.isEmpty {
            dict["dropped"] = .string(Data(dropped.flatMap { Array($0.address) }))
        }
        if !added6.isEmpty {
            dict["added6"] = .string(Data(added6.flatMap { Array($0.address) }))
            dict["added6.f"] = .string(Data(added6.map { $0.flags }))
        }
        return BencodeEncoder.encode(.dictionary(dict))
    }

    static func decode(_ data: Data) throws -> PEXMessage {
        let value = try BencodeDecoder.decode(data)
        guard let dict = value.dictValue else { throw DecodeError.invalid }

        func parsePeers(key: String, flagsKey: String, stride: Int) -> [PeerInfo] {
            guard let addedData = dict[key]?.dataValue else { return [] }
            let flagsData = dict[flagsKey]?.dataValue ?? Data()
            var peers: [PeerInfo] = []
            var i = 0
            var pi = 0
            while i + stride <= addedData.count {
                let addr = addedData[addedData.index(addedData.startIndex, offsetBy: i)..<addedData.index(addedData.startIndex, offsetBy: i + stride)]
                let flag = pi < flagsData.count ? flagsData[flagsData.index(flagsData.startIndex, offsetBy: pi)] : 0
                peers.append(PeerInfo(address: Data(addr), flags: flag))
                i += stride
                pi += 1
            }
            return peers
        }

        return PEXMessage(
            added: parsePeers(key: "added", flagsKey: "added.f", stride: 6),
            dropped: parsePeers(key: "dropped", flagsKey: "dropped.f", stride: 6),
            added6: parsePeers(key: "added6", flagsKey: "added6.f", stride: 18),
            dropped6: parsePeers(key: "dropped6", flagsKey: "dropped6.f", stride: 18)
        )
    }

    enum DecodeError: Error { case invalid }
}
