import Foundation
import CryptoKit

// MARK: - File Entry

struct TorrentFileEntry: Sendable, Identifiable {
    let id: UUID
    let path: [String]          // path components
    let length: Int64
    let paddingFile: Bool
    var sha256: Data?           // BT v2 file hash
    var md5sum: Data?

    var displayPath: String { path.joined(separator: "/") }
    var filename: String { path.last ?? "Unknown" }

    init(path: [String], length: Int64, paddingFile: Bool = false, sha256: Data? = nil) {
        self.id = UUID()
        self.path = path
        self.length = length
        self.paddingFile = paddingFile
        self.sha256 = sha256
    }
}

// MARK: - Tracker Group

struct AnnounceGroup: Sendable {
    let urls: [String]  // tier
}

// MARK: - Torrent Metadata

struct TorrentMetadata: Sendable {
    // Core
    let infoHash: HybridInfoHash
    let name: String
    let pieceLength: Int64
    let pieces: [Data]          // SHA1 hashes per piece (v1)
    let pieceLayersV2: [String: Data]?  // file root hash -> piece layers (v2)

    // Files
    let files: [TorrentFileEntry]
    let totalLength: Int64

    // Network
    let announceList: [AnnounceGroup]
    let webSeeds: [String]
    let nodes: [(host: String, port: Int)]  // DHT nodes

    // Metadata
    let comment: String?
    let createdBy: String?
    let creationDate: Date?
    let isPrivate: Bool

    // Protocol Version
    let version: TorrentVersion

    var isSingleFile: Bool { files.count == 1 }
    var pieceCount: Int { pieces.count }

    // Compute byte offset + file for a piece index
    func fileLayout() -> [(file: TorrentFileEntry, offset: Int64, length: Int64)] {
        var result: [(TorrentFileEntry, Int64, Int64)] = []
        var offset: Int64 = 0
        for file in files {
            result.append((file, offset, file.length))
            offset += file.length
        }
        return result
    }
}

enum TorrentVersion: Sendable {
    case v1
    case v2
    case hybrid
}

// MARK: - Parser

enum TorrentParser {
    enum ParseError: Error, Sendable {
        case invalidTorrentFile(String)
        case missingField(String)
        case unsupportedVersion
    }

    static func parse(data: Data) throws -> TorrentMetadata {
        let root = try BencodeDecoder.decode(data)
        guard case .dictionary = root else {
            throw ParseError.invalidTorrentFile("Root must be a dictionary")
        }

        let infoBencodeData = try extractRawInfoDict(from: data)
        let infoValue = root["info"] ?? (try { throw ParseError.missingField("info") }())

        guard let info = infoValue.dictValue else {
            throw ParseError.invalidTorrentFile("info must be a dictionary")
        }

        // Info hash
        let v1Hash = try InfoHash.from(infoDict: infoValue!)
        var v2Hash: InfoHash? = nil

        // BT v2: meta version field
        let metaVersion = info["meta version"]?.intValue
        var torrentVersion: TorrentVersion = .v1

        if metaVersion == 2 {
            v2Hash = try InfoHash.v2From(infoDict: infoValue!)
            torrentVersion = .v2
        }

        if v2Hash != nil && v1Hash.data.count == 20 {
            // Has both: hybrid
            // For pure v2, check if pieces key exists
            if info["pieces"] != nil {
                torrentVersion = .hybrid
            }
        }

        let hybridHash = HybridInfoHash(v1: v1Hash, v2: v2Hash)

        // Name
        guard let name = info["name"]?.stringValue ?? info["name.utf-8"]?.stringValue else {
            throw ParseError.missingField("info.name")
        }

        // Piece length
        guard let pieceLength = info["piece length"]?.intValue else {
            throw ParseError.missingField("info.piece length")
        }

        // Pieces (v1)
        var pieces: [Data] = []
        if let piecesData = info["pieces"]?.dataValue {
            guard piecesData.count % 20 == 0 else {
                throw ParseError.invalidTorrentFile("Pieces field length must be multiple of 20")
            }
            pieces = stride(from: 0, to: piecesData.count, by: 20).map {
                piecesData[$0..<($0 + 20)]
            }
        }

        // Files
        var files: [TorrentFileEntry] = []
        if let fileList = info["files"]?.listValue {
            // Multi-file
            for fileItem in fileList {
                guard let fileDict = fileItem.dictValue,
                      let length = fileDict["length"]?.intValue else { continue }
                let pathComponents: [String]
                if let pathUtf8 = fileDict["path.utf-8"]?.listValue {
                    pathComponents = pathUtf8.compactMap { $0.stringValue }
                } else if let path = fileDict["path"]?.listValue {
                    pathComponents = path.compactMap { $0.stringValue }
                } else {
                    pathComponents = ["unknown"]
                }
                let isPadding = fileDict["attr"]?.stringValue?.contains("p") ?? false
                let sha256 = fileDict["sha256"]?.dataValue
                files.append(TorrentFileEntry(path: pathComponents, length: length, paddingFile: isPadding, sha256: sha256))
            }
        } else if let length = info["length"]?.intValue {
            // Single-file
            files = [TorrentFileEntry(path: [name], length: length)]
        } else {
            throw ParseError.missingField("files or length")
        }

        let totalLength = files.reduce(0) { $0 + $1.length }

        // Announce list (tiered trackers)
        var announceGroups: [AnnounceGroup] = []
        if let tierList = root["announce-list"]?.listValue {
            for tier in tierList {
                if let urls = tier.listValue?.compactMap({ $0.stringValue }), !urls.isEmpty {
                    announceGroups.append(AnnounceGroup(urls: urls))
                }
            }
        } else if let announce = root["announce"]?.stringValue {
            announceGroups = [AnnounceGroup(urls: [announce])]
        }

        // Web seeds
        var webSeeds: [String] = []
        if let urlList = root["url-list"]?.listValue {
            webSeeds = urlList.compactMap { $0.stringValue }
        } else if let url = root["url-list"]?.stringValue {
            webSeeds = [url]
        }

        // DHT nodes
        var dhtNodes: [(String, Int)] = []
        if let nodeList = root["nodes"]?.listValue {
            for node in nodeList {
                if let pair = node.listValue,
                   pair.count == 2,
                   let host = pair[0].stringValue,
                   let port = pair[1].intValue {
                    dhtNodes.append((host, Int(port)))
                }
            }
        }

        // Metadata
        let comment = root["comment"]?.stringValue
        let createdBy = root["created by"]?.stringValue
        let creationDate: Date? = {
            guard let ts = root["creation date"]?.intValue else { return nil }
            return Date(timeIntervalSince1970: Double(ts))
        }()
        let isPrivate = info["private"]?.intValue == 1

        // Piece layers (v2)
        var pieceLayersV2: [String: Data]? = nil
        if let pieceLayers = root["piece layers"]?.dictValue {
            pieceLayersV2 = pieceLayers.compactMapValues { $0.dataValue }
        }

        return TorrentMetadata(
            infoHash: hybridHash,
            name: name,
            pieceLength: pieceLength,
            pieces: pieces,
            pieceLayersV2: pieceLayersV2,
            files: files,
            totalLength: totalLength,
            announceList: announceGroups,
            webSeeds: webSeeds,
            nodes: dhtNodes,
            comment: comment,
            createdBy: createdBy,
            creationDate: creationDate,
            isPrivate: isPrivate,
            version: torrentVersion
        )
    }

    // Extract raw bencoded info dict bytes for hashing
    private static func extractRawInfoDict(from data: Data) throws -> Data {
        // Find "4:info" then extract the value
        guard let infoKey = "4:info".data(using: .utf8) else {
            throw ParseError.invalidTorrentFile("Encoding error")
        }
        guard let range = data.range(of: infoKey) else {
            throw ParseError.missingField("info key")
        }
        var idx = range.upperBound
        // Now decode length to find end of info dict
        let snapshot = data
        _ = try { () throws -> BencodeValue in
            var i = idx
            return try BencodeDecoder.decode(snapshot[i...])
        }()
        return data[idx...]
    }
}
