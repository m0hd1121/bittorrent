import Foundation

// MARK: - Magnet Link

struct MagnetLink: Sendable {
    let infoHash: InfoHash
    let displayName: String?
    let trackers: [String]
    let webSeeds: [String]
    let dhtNodes: [(String, Int)]
    let peers: [String]         // xs= exact source
    let keywords: [String]      // kt=

    enum ParseError: Error, Sendable {
        case invalidScheme
        case missingInfoHash
        case invalidInfoHash(String)
        case unsupportedHashType
    }

    init(url: URL) throws {
        guard url.scheme?.lowercased() == "magnet" else {
            throw ParseError.invalidScheme
        }

        // Parse query components from magnet: URI
        // URLComponents doesn't parse magnet: properly, so do it manually
        let urlString = url.absoluteString
        guard let queryStart = urlString.firstIndex(of: "?") else {
            throw ParseError.missingInfoHash
        }
        let queryString = String(urlString[urlString.index(after: queryStart)...])
        let params = Self.parseQuery(queryString)

        // Extract xt= (exact topic) for info hash
        var foundHash: InfoHash? = nil
        for xt in params["xt"] ?? [] {
            if xt.hasPrefix("urn:btih:") {
                let hashStr = String(xt.dropFirst("urn:btih:".count))
                if hashStr.count == 40 {
                    // Hex
                    if let hashData = Data(hexString: hashStr) {
                        foundHash = try InfoHash(v1: hashData)
                    }
                } else if hashStr.count == 32 {
                    // Base32
                    if let hashData = Data(base32Encoded: hashStr) {
                        foundHash = try InfoHash(v1: hashData)
                    }
                }
                break
            } else if xt.hasPrefix("urn:btmh:") {
                // BT v2 multihash
                let hashStr = String(xt.dropFirst("urn:btmh:".count))
                if hashStr.count == 68, hashStr.hasPrefix("1220") {
                    // SHA256: 0x12 0x20 + 32 bytes
                    let hexHash = String(hashStr.dropFirst(4))
                    if let hashData = Data(hexString: hexHash) {
                        foundHash = try InfoHash(v2: hashData)
                    }
                }
                break
            }
        }

        guard let hash = foundHash else {
            throw ParseError.missingInfoHash
        }

        self.infoHash = hash
        self.displayName = (params["dn"]?.first).flatMap { $0.removingPercentEncoding }
        self.trackers = (params["tr"] ?? []).compactMap { $0.removingPercentEncoding }
        self.webSeeds = (params["ws"] ?? []).compactMap { $0.removingPercentEncoding }
        self.peers = (params["xs"] ?? []).compactMap { $0.removingPercentEncoding }
        self.keywords = (params["kt"] ?? [])
            .flatMap { $0.components(separatedBy: "+") }
            .compactMap { $0.removingPercentEncoding }

        // x.pe= for peer hints
        var nodes: [(String, Int)] = []
        for node in params["x.pe"] ?? [] {
            if let decoded = node.removingPercentEncoding,
               let lastColon = decoded.lastIndex(of: ":"),
               let port = Int(decoded[decoded.index(after: lastColon)...]) {
                let host = String(decoded[..<lastColon])
                nodes.append((host, port))
            }
        }
        self.dhtNodes = nodes
    }

    private static func parseQuery(_ query: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        let pairs = query.components(separatedBy: "&")
        for pair in pairs {
            let parts = pair.components(separatedBy: "=")
            guard parts.count >= 1 else { continue }
            let key = parts[0]
            let value = parts.count >= 2 ? parts[1...].joined(separator: "=") : ""
            result[key, default: []].append(value)
        }
        return result
    }
}

// MARK: - Base32 Decoding

private extension Data {
    init?(base32Encoded string: String) {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        let uppercased = string.uppercased()
        var bits = 0
        var bitsCount = 0
        var bytes: [UInt8] = []

        for char in uppercased {
            guard let index = alphabet.firstIndex(of: char) else {
                if char == "=" { break }
                return nil
            }
            let value = alphabet.distance(from: alphabet.startIndex, to: index)
            bits = (bits << 5) | value
            bitsCount += 5
            if bitsCount >= 8 {
                bitsCount -= 8
                bytes.append(UInt8((bits >> bitsCount) & 0xFF))
            }
        }
        self.init(bytes)
    }
}
