import Foundation
import Network
import os.log

// MARK: - Tracker Event

enum TrackerEvent: String, Sendable {
    case started, stopped, completed, empty = ""
}

// MARK: - Tracker Response

struct TrackerResponse: Sendable {
    let interval: Int
    let minInterval: Int?
    let trackerId: String?
    let complete: Int     // seeders
    let incomplete: Int   // leechers
    let peers: Data       // compact IPv4
    let peers6: Data?     // compact IPv6
    let warningMessage: String?
}

// MARK: - Tracker Status

struct TrackerStatus: Sendable, Identifiable {
    let id: UUID
    let url: String
    var lastAnnounce: Date?
    var nextAnnounce: Date?
    var seeders: Int
    var leechers: Int
    var statusMessage: String
    var isWorking: Bool

    init(url: String) {
        self.id = UUID()
        self.url = url
        self.seeders = 0
        self.leechers = 0
        self.statusMessage = "Waiting"
        self.isWorking = false
    }
}

// MARK: - Tracker Manager

actor TrackerManager {
    private let infoHash: Data
    private let localPeerID: Data
    private let listenPort: UInt16
    private let announceGroups: [AnnounceGroup]

    private var trackerStatuses: [String: TrackerStatus] = [:]
    private var announceTasks: [String: Task<Void, Never>] = [:]
    private var downloadedBytes: Int64 = 0
    private var uploadedBytes: Int64 = 0
    private var leftBytes: Int64 = 0

    private let logger = Logger(subsystem: "com.bitflow.engine", category: "TrackerManager")

    var onPeersReceived: (@Sendable ([Data]) -> Void)?
    var onStatusUpdated: (@Sendable ([TrackerStatus]) -> Void)?

    init(infoHash: Data, peerID: Data, port: UInt16, announceGroups: [AnnounceGroup]) {
        self.infoHash = infoHash
        self.localPeerID = peerID
        self.listenPort = port
        self.announceGroups = announceGroups

        for group in announceGroups {
            for url in group.urls {
                trackerStatuses[url] = TrackerStatus(url: url)
            }
        }
    }

    func updateStats(downloaded: Int64, uploaded: Int64, left: Int64) {
        self.downloadedBytes = downloaded
        self.uploadedBytes = uploaded
        self.leftBytes = left
    }

    // MARK: - Announce

    func startAnnouncing() {
        // Announce to each tier (first working tracker per tier wins)
        for group in announceGroups {
            for url in group.urls {
                scheduleAnnounce(url: url, event: .started, after: 0)
            }
        }
    }

    func stopAnnouncing() async {
        for task in announceTasks.values { task.cancel() }
        announceTasks.removeAll()

        // Send stopped event to all working trackers
        let working = trackerStatuses.filter { $0.value.isWorking }.map { $0.key }
        await withTaskGroup(of: Void.self) { group in
            for url in working {
                group.addTask { [self] in
                    _ = try? await self.announce(url: url, event: .stopped)
                }
            }
        }
    }

    func announceCompleted() async {
        let working = trackerStatuses.filter { $0.value.isWorking }.map { $0.key }
        for url in working {
            _ = try? await announce(url: url, event: .completed)
        }
    }

    private func scheduleAnnounce(url: String, event: TrackerEvent, after delay: TimeInterval) {
        announceTasks[url]?.cancel()
        announceTasks[url] = Task.detached(priority: .utility) { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled else { return }
            await self?.performAnnounce(url: url, event: event)
        }
    }

    private func performAnnounce(url: String, event: TrackerEvent) async {
        var retryDelay: TimeInterval = 30

        for attempt in 0..<4 {
            do {
                let response = try await announce(url: url, event: event)
                trackerStatuses[url]?.isWorking = true
                trackerStatuses[url]?.lastAnnounce = .now
                trackerStatuses[url]?.seeders = response.complete
                trackerStatuses[url]?.leechers = response.incomplete
                trackerStatuses[url]?.statusMessage = "OK (\(response.complete) seeds, \(response.incomplete) leechers)"
                trackerStatuses[url]?.nextAnnounce = Date(timeIntervalSinceNow: Double(response.interval))
                notifyStatus()

                // Deliver peers
                var peerDataBlocks: [Data] = []
                if !response.peers.isEmpty { peerDataBlocks.append(response.peers) }
                if let p6 = response.peers6, !p6.isEmpty { peerDataBlocks.append(p6) }
                onPeersReceived?(peerDataBlocks)

                // Schedule next
                let interval = max(60, response.minInterval ?? response.interval)
                scheduleAnnounce(url: url, event: .empty, after: Double(interval))
                return

            } catch {
                let errMsg = "Error: \(error.localizedDescription)"
                trackerStatuses[url]?.isWorking = false
                trackerStatuses[url]?.statusMessage = errMsg
                notifyStatus()
                logger.warning("Tracker \(url) attempt \(attempt+1) failed: \(error)")

                if attempt < 3 {
                    try? await Task.sleep(for: .seconds(retryDelay))
                    retryDelay = min(retryDelay * 2, 300)
                }
            }
        }
        // All retries exhausted - schedule a longer retry
        scheduleAnnounce(url: url, event: .empty, after: 600)
    }

    private func announce(url: String, event: TrackerEvent) async throws -> TrackerResponse {
        if url.hasPrefix("udp://") {
            return try await UDPTracker.announce(url: url, infoHash: infoHash, peerID: localPeerID, port: listenPort, event: event, downloaded: downloadedBytes, uploaded: uploadedBytes, left: leftBytes)
        } else {
            return try await HTTPTracker.announce(url: url, infoHash: infoHash, peerID: localPeerID, port: listenPort, event: event, downloaded: downloadedBytes, uploaded: uploadedBytes, left: leftBytes)
        }
    }

    private func notifyStatus() {
        let statuses = Array(trackerStatuses.values)
        onStatusUpdated?(statuses)
    }

    var allStatuses: [TrackerStatus] { Array(trackerStatuses.values) }
}

// MARK: - HTTP Tracker

enum HTTPTracker {
    enum TrackerError: Error, Sendable {
        case invalidURL
        case invalidResponse
        case trackerError(String)
        case networkError(Error)
    }

    static func announce(
        url: String,
        infoHash: Data,
        peerID: Data,
        port: UInt16,
        event: TrackerEvent,
        downloaded: Int64,
        uploaded: Int64,
        left: Int64
    ) async throws -> TrackerResponse {
        guard var components = URLComponents(string: url) else {
            throw TrackerError.invalidURL
        }

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "info_hash", value: percentEncode(infoHash)),
            URLQueryItem(name: "peer_id", value: percentEncode(peerID)),
            URLQueryItem(name: "port", value: "\(port)"),
            URLQueryItem(name: "uploaded", value: "\(uploaded)"),
            URLQueryItem(name: "downloaded", value: "\(downloaded)"),
            URLQueryItem(name: "left", value: "\(left)"),
            URLQueryItem(name: "compact", value: "1"),
            URLQueryItem(name: "no_peer_id", value: "1"),
            URLQueryItem(name: "numwant", value: "200"),
            URLQueryItem(name: "supportcrypto", value: "1"),
        ]

        if event != .empty {
            queryItems.append(URLQueryItem(name: "event", value: event.rawValue))
        }

        // Also request IPv6 peers
        queryItems.append(URLQueryItem(name: "ipv6", value: ""))

        components.queryItems = queryItems
        guard let requestURL = components.url else { throw TrackerError.invalidURL }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        let session = URLSession(configuration: config)

        do {
            let (data, response) = try await session.data(from: requestURL)
            guard let httpResponse = response as? HTTPURLResponse,
                  200..<300 ~= httpResponse.statusCode else {
                throw TrackerError.invalidResponse
            }

            return try parseResponse(data)
        } catch let error as TrackerError {
            throw error
        } catch {
            throw TrackerError.networkError(error)
        }
    }

    private static func parseResponse(_ data: Data) throws -> TrackerResponse {
        let decoded = try BencodeDecoder.decode(data)
        guard let dict = decoded.dictValue else { throw TrackerError.invalidResponse }

        if let failure = dict["failure reason"]?.stringValue {
            throw TrackerError.trackerError(failure)
        }

        let interval = Int(dict["interval"]?.intValue ?? 1800)
        let minInterval = dict["min interval"]?.intValue.map { Int($0) }
        let trackerId = dict["tracker id"]?.stringValue
        let complete = Int(dict["complete"]?.intValue ?? 0)
        let incomplete = Int(dict["incomplete"]?.intValue ?? 0)
        let warning = dict["warning message"]?.stringValue

        var peers = Data()
        if let compactPeers = dict["peers"]?.dataValue {
            peers = compactPeers
        } else if let peerList = dict["peers"]?.listValue {
            // Non-compact (fallback)
            for peer in peerList {
                if let peerDict = peer.dictValue,
                   let ip = peerDict["ip"]?.stringValue,
                   let port = peerDict["port"]?.intValue {
                    if let addr = IPv4Address(ip) {
                        var bytes = addr.rawValue
                        var bigPort = UInt16(port).bigEndian
                        peers.append(bytes)
                        withUnsafeBytes(of: &bigPort) { peers.append(contentsOf: $0) }
                    }
                }
            }
        }

        let peers6 = dict["peers6"]?.dataValue

        return TrackerResponse(
            interval: interval,
            minInterval: minInterval,
            trackerId: trackerId,
            complete: complete,
            incomplete: incomplete,
            peers: peers,
            peers6: peers6,
            warningMessage: warning
        )
    }

    private static func percentEncode(_ data: Data) -> String {
        var encoded = ""
        for byte in data {
            let ch = Character(UnicodeScalar(byte))
            if ch.isLetter || ch.isNumber || "-_.~".contains(ch) {
                encoded.append(ch)
            } else {
                encoded += String(format: "%%%02X", byte)
            }
        }
        return encoded
    }
}

// MARK: - UDP Tracker (BEP 15)

enum UDPTracker {
    static let connectMagic: UInt64 = 0x41727101980

    enum TrackerError: Error, Sendable {
        case invalidURL
        case connectionFailed
        case timeout
        case invalidResponse
        case actionError(String)
    }

    static func announce(
        url: String,
        infoHash: Data,
        peerID: Data,
        port: UInt16,
        event: TrackerEvent,
        downloaded: Int64,
        uploaded: Int64,
        left: Int64
    ) async throws -> TrackerResponse {
        guard let components = URLComponents(string: url),
              let host = components.host,
              let udpPort = components.port.map({ UInt16($0) }) ?? Optional(6969) else {
            throw TrackerError.invalidURL
        }

        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: udpPort) ?? .init(rawValue: 6969)!,
            using: .udp
        )

        return try await withCheckedThrowingContinuation { continuation in
            conn.stateUpdateHandler = { state in
                if case .ready = state {
                    Task {
                        do {
                            let response = try await Self.performAnnounce(
                                conn: conn,
                                infoHash: infoHash,
                                peerID: peerID,
                                port: port,
                                event: event,
                                downloaded: downloaded,
                                uploaded: uploaded,
                                left: left
                            )
                            conn.cancel()
                            continuation.resume(returning: response)
                        } catch {
                            conn.cancel()
                            continuation.resume(throwing: error)
                        }
                    }
                } else if case .failed(let err) = state {
                    continuation.resume(throwing: TrackerError.connectionFailed)
                }
            }
            conn.start(queue: .global(qos: .utility))
        }
    }

    private static func performAnnounce(
        conn: NWConnection,
        infoHash: Data,
        peerID: Data,
        port: UInt16,
        event: TrackerEvent,
        downloaded: Int64,
        uploaded: Int64,
        left: Int64
    ) async throws -> TrackerResponse {
        // Step 1: Connect request
        let txID = UInt32.random(in: 0..<UInt32.max)
        var connectReq = Data(capacity: 16)
        connectReq.append(bigEndian64: Self.connectMagic)
        connectReq.append(bigEndian: UInt32(0))  // action: connect
        connectReq.append(bigEndian: txID)

        try await send(conn, data: connectReq)
        let connectResp = try await receive(conn, timeout: 15)

        guard connectResp.count >= 16 else { throw TrackerError.invalidResponse }
        let respAction = connectResp.readUInt32(at: 0)
        let respTxID = connectResp.readUInt32(at: 4)
        guard respAction == 0, respTxID == txID else { throw TrackerError.invalidResponse }

        var connID = Data(connectResp[8..<16])

        // Step 2: Announce
        let announceTxID = UInt32.random(in: 0..<UInt32.max)
        var announceReq = Data(capacity: 98)
        announceReq.append(connID)
        announceReq.append(bigEndian: UInt32(1))  // action: announce
        announceReq.append(bigEndian: announceTxID)
        announceReq.append(infoHash)
        announceReq.append(peerID)

        var dl = downloaded.bigEndian
        withUnsafeBytes(of: &dl) { announceReq.append(contentsOf: $0) }
        var left64 = left.bigEndian
        withUnsafeBytes(of: &left64) { announceReq.append(contentsOf: $0) }
        var ul = uploaded.bigEndian
        withUnsafeBytes(of: &ul) { announceReq.append(contentsOf: $0) }

        let eventCode: UInt32
        switch event {
        case .completed: eventCode = 1
        case .started:   eventCode = 2
        case .stopped:   eventCode = 3
        default:         eventCode = 0
        }
        announceReq.append(bigEndian: eventCode)
        announceReq.append(bigEndian: UInt32(0))   // IP: 0 = default
        announceReq.append(bigEndian: UInt32.random(in: 0..<UInt32.max))  // key
        announceReq.append(bigEndian: UInt32(200)) // numwant
        announceReq.append(bigEndian: port)

        try await send(conn, data: announceReq)
        let announceResp = try await receive(conn, timeout: 15)

        guard announceResp.count >= 20 else { throw TrackerError.invalidResponse }
        let aAction = announceResp.readUInt32(at: 0)
        let aTxID = announceResp.readUInt32(at: 4)
        guard aAction == 1, aTxID == announceTxID else { throw TrackerError.invalidResponse }

        let interval = Int(announceResp.readUInt32(at: 8))
        let leechers = Int(announceResp.readUInt32(at: 12))
        let seeders = Int(announceResp.readUInt32(at: 16))

        let peersData = Data(announceResp[20...])

        return TrackerResponse(
            interval: interval,
            minInterval: nil,
            trackerId: nil,
            complete: seeders,
            incomplete: leechers,
            peers: peersData,
            peers6: nil,
            warningMessage: nil
        )
    }

    private static func send(_ conn: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) }
                else { cont.resume() }
            })
        }
    }

    private static func receive(_ conn: NWConnection, timeout: TimeInterval) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { cont in
                    conn.receiveMessage { data, _, _, error in
                        if let data { cont.resume(returning: data) }
                        else { cont.resume(throwing: error ?? TrackerError.invalidResponse) }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw TrackerError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

extension Data {
    mutating func append(bigEndian64 value: UInt64) {
        var v = value.bigEndian
        withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
