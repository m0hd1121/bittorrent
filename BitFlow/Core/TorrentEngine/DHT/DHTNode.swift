import Foundation
import Network
import os.log

// MARK: - DHT Node ID

struct DHTNodeID: Sendable, Hashable, Comparable {
    let data: Data  // 20 bytes

    init() {
        var bytes = [UInt8](repeating: 0, count: 20)
        for i in 0..<20 { bytes[i] = UInt8.random(in: 0...255) }
        self.data = Data(bytes)
    }

    init(data: Data) {
        self.data = data.prefix(20)
    }

    func distance(to other: DHTNodeID) -> Data {
        let a = Array(data)
        let b = Array(other.data)
        return Data(zip(a, b).map { $0.0 ^ $0.1 })
    }

    static func < (lhs: DHTNodeID, rhs: DHTNodeID) -> Bool {
        lhs.data.lexicographicallyPrecedes(rhs.data)
    }
}

// MARK: - DHT Peer (compact node info)

struct DHTNodeInfo: Sendable, Hashable {
    let id: DHTNodeID
    let host: String
    let port: UInt16
    var lastSeen: Date
    var failCount: Int

    var isGood: Bool { failCount < 2 && lastSeen.timeIntervalSinceNow > -15 * 60 }
}

// MARK: - K-Bucket

final class KBucket: @unchecked Sendable {
    static let k = 8
    var nodes: [DHTNodeInfo] = []
    var replacementCache: [DHTNodeInfo] = []
    var lastChanged: Date = .now

    func add(_ node: DHTNodeInfo) -> Bool {
        if let idx = nodes.firstIndex(where: { $0.id == node.id }) {
            nodes[idx] = node
            nodes[idx].lastSeen = .now
            return true
        }
        if nodes.count < Self.k {
            nodes.append(node)
            lastChanged = .now
            return true
        }
        // Replace bad nodes
        if let badIdx = nodes.firstIndex(where: { !$0.isGood }) {
            nodes[badIdx] = node
            lastChanged = .now
            return true
        }
        // Add to replacement cache
        if replacementCache.count < Self.k {
            replacementCache.append(node)
        }
        return false
    }

    func remove(id: DHTNodeID) {
        nodes.removeAll { $0.id == id }
        if let replacement = replacementCache.first {
            replacementCache.removeFirst()
            nodes.append(replacement)
        }
    }

    func closestNodes(to target: DHTNodeID, count: Int) -> [DHTNodeInfo] {
        nodes.sorted { a, b in
            a.id.distance(to: target).lexicographicallyPrecedes(b.id.distance(to: target))
        }.prefix(count).map { $0 }
    }
}

// MARK: - Routing Table

actor DHTRoutingTable {
    private let localID: DHTNodeID
    private var buckets: [KBucket] = [KBucket()]

    init(localID: DHTNodeID) {
        self.localID = localID
    }

    func add(_ node: DHTNodeInfo) {
        guard node.id != localID else { return }
        let bucket = findBucket(for: node.id)
        _ = bucket.add(node)
    }

    func remove(id: DHTNodeID) {
        findBucket(for: id).remove(id: id)
    }

    func closestNodes(to target: DHTNodeID, count: Int = 8) -> [DHTNodeInfo] {
        buckets.flatMap { $0.nodes }
            .sorted { a, b in
                a.id.distance(to: target).lexicographicallyPrecedes(b.id.distance(to: target))
            }
            .prefix(count)
            .map { $0 }
    }

    func allNodes() -> [DHTNodeInfo] { buckets.flatMap { $0.nodes } }

    private func findBucket(for id: DHTNodeID) -> KBucket {
        // Simplified: use single bucket until split logic needed
        return buckets[0]
    }
}

// MARK: - DHT Engine (BEP 5 Kademlia)

actor DHTEngine {
    private let localID: DHTNodeID
    private let routingTable: DHTRoutingTable
    private var connection: NWConnection?
    private let listenPort: UInt16
    private let logger = Logger(subsystem: "com.bitflow.engine", category: "DHT")
    private var pendingQueries: [String: CheckedContinuation<BencodeValue, Error>] = [:]
    private var bootstrapNodes: [(String, UInt16)]
    private var listener: NWListener?

    var onPeersFound: (@Sendable ([PeerInfo]) -> Void)?
    var onNodeFound: (@Sendable (DHTNodeInfo) -> Void)?

    init(port: UInt16) {
        self.localID = DHTNodeID()
        self.routingTable = DHTRoutingTable(localID: localID)
        self.listenPort = port
        self.bootstrapNodes = [
            ("router.bittorrent.com", 6881),
            ("router.utorrent.com", 6881),
            ("dht.transmissionbt.com", 6881),
            ("dht.aelitis.com", 6881),
        ]
    }

    func start() async {
        await startListener()
        await bootstrap()
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Listener

    private func startListener() async {
        do {
            let params = NWParameters.udp
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: listenPort) ?? .init(rawValue: 6881)!)
            listener?.newConnectionHandler = { [weak self] conn in
                Task { [weak self] in
                    await self?.handleIncoming(conn)
                }
            }
            listener?.start(queue: .global(qos: .utility))
            logger.info("DHT listening on port \(self.listenPort)")
        } catch {
            logger.error("DHT listener failed: \(error)")
        }
    }

    private func handleIncoming(_ conn: NWConnection) async {
        conn.start(queue: .global(qos: .utility))
        conn.receiveMessage { [weak self] data, context, _, error in
            guard let data else { return }
            if let endpoint = context?.localAddress {
                Task { [weak self] in
                    await self?.handleMessage(data, from: conn)
                }
            }
        }
    }

    private func handleMessage(_ data: Data, from conn: NWConnection) async {
        guard let value = try? BencodeDecoder.decode(data),
              let dict = value.dictValue else { return }

        let msgType = dict["y"]?.stringValue ?? ""
        let txID = dict["t"]?.dataValue?.hexString ?? ""

        switch msgType {
        case "q":
            await handleQuery(dict, txID: txID, conn: conn)
        case "r":
            if let cont = pendingQueries.removeValue(forKey: txID) {
                if let r = dict["r"] { cont.resume(returning: r) }
            }
        case "e":
            if let cont = pendingQueries.removeValue(forKey: txID) {
                cont.resume(throwing: DHTError.errorResponse)
            }
        default: break
        }
    }

    private func handleQuery(_ dict: [String: BencodeValue], txID: String, conn: NWConnection) async {
        let q = dict["q"]?.stringValue ?? ""
        guard let args = dict["a"]?.dictValue else { return }
        guard let nodeIDData = args["id"]?.dataValue else { return }
        let nodeID = DHTNodeID(data: nodeIDData)

        switch q {
        case "ping":
            await sendPong(txID: txID, conn: conn)

        case "find_node":
            guard let targetData = args["target"]?.dataValue else { return }
            let target = DHTNodeID(data: targetData)
            let closest = await routingTable.closestNodes(to: target)
            await sendFindNodeResponse(txID: txID, nodes: closest, conn: conn)

        case "get_peers":
            guard let infoHashData = args["info_hash"]?.dataValue else { return }
            let target = DHTNodeID(data: infoHashData)
            let closest = await routingTable.closestNodes(to: target)
            await sendGetPeersResponse(txID: txID, nodes: closest, conn: conn)

        case "announce_peer":
            break // Accept announces from peers

        default: break
        }
    }

    // MARK: - Bootstrap

    private func bootstrap() async {
        for (host, port) in bootstrapNodes {
            let nodeID = DHTNodeID()
            let node = DHTNodeInfo(id: nodeID, host: host, port: port, lastSeen: .now, failCount: 0)
            await routingTable.add(node)
            await findNode(target: localID, via: node)
        }
    }

    // MARK: - Get Peers

    func getPeers(infoHash: Data) async {
        let target = DHTNodeID(data: infoHash)
        let initial = await routingTable.closestNodes(to: target)

        await withTaskGroup(of: Void.self) { group in
            for node in initial.prefix(8) {
                group.addTask { [weak self] in
                    await self?.queryGetPeers(infoHash: infoHash, from: node)
                }
            }
        }
    }

    private func queryGetPeers(infoHash: Data, from node: DHTNodeInfo) async {
        let payload: BencodeValue = .dictionary([
            "t": .string(randomTransactionID()),
            "y": .string("q".data(using: .utf8)!),
            "q": .string("get_peers".data(using: .utf8)!),
            "a": .dictionary([
                "id": .string(localID.data),
                "info_hash": .string(infoHash)
            ])
        ])

        guard let response = try? await sendQuery(payload, to: node),
              let respDict = response.dictValue else { return }

        if let valuesData = respDict["values"]?.listValue {
            var peers: [PeerInfo] = []
            for item in valuesData {
                if let compact = item.dataValue, compact.count >= 6 {
                    let ip = compact[..<compact.index(compact.startIndex, offsetBy: 4)].map { String($0) }.joined(separator: ".")
                    let portData = compact[compact.index(compact.startIndex, offsetBy: 4)..<compact.index(compact.startIndex, offsetBy: 6)]
                    let port = portData.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
                    peers.append(PeerInfo(host: ip, port: port, source: .dht, lastSeen: .now, failCount: 0))
                }
            }
            onPeersFound?(peers)
        }

        if let nodesData = respDict["nodes"]?.dataValue {
            parseCompactNodes(nodesData)
        }
    }

    private func findNode(target: DHTNodeID, via node: DHTNodeInfo) async {
        let payload: BencodeValue = .dictionary([
            "t": .string(randomTransactionID()),
            "y": .string("q".data(using: .utf8)!),
            "q": .string("find_node".data(using: .utf8)!),
            "a": .dictionary([
                "id": .string(localID.data),
                "target": .string(target.data)
            ])
        ])
        _ = try? await sendQuery(payload, to: node)
    }

    private func parseCompactNodes(_ data: Data) {
        var i = data.startIndex
        while data.distance(from: i, to: data.endIndex) >= 26 {
            let idData = data[i..<data.index(i, offsetBy: 20)]
            let ipData = data[data.index(i, offsetBy: 20)..<data.index(i, offsetBy: 24)]
            let portData = data[data.index(i, offsetBy: 24)..<data.index(i, offsetBy: 26)]
            let ip = ipData.map { String($0) }.joined(separator: ".")
            let port = portData.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
            let node = DHTNodeInfo(id: DHTNodeID(data: Data(idData)), host: ip, port: port, lastSeen: .now, failCount: 0)
            Task { await self.routingTable.add(node) }
            i = data.index(i, offsetBy: 26)
        }
    }

    // MARK: - Send/Receive

    private func sendQuery(_ payload: BencodeValue, to node: DHTNodeInfo) async throws -> BencodeValue {
        let data = BencodeEncoder.encode(payload)
        let txID = payload.dictValue?["t"]?.dataValue?.hexString ?? ""

        return try await withCheckedThrowingContinuation { cont in
            pendingQueries[txID] = cont
            let conn = NWConnection(
                host: NWEndpoint.Host(node.host),
                port: NWEndpoint.Port(rawValue: node.port) ?? .init(rawValue: 6881)!,
                using: .udp
            )
            conn.stateUpdateHandler = { state in
                if case .ready = state {
                    conn.send(content: data, completion: .contentProcessed { _ in })
                    conn.receiveMessage { [weak self] data, _, _, _ in
                        conn.cancel()
                        if let data, let v = try? BencodeDecoder.decode(data) {
                            Task { [weak self] in
                                await self?.handleMessage(data, from: conn)
                            }
                        }
                    }
                }
            }
            conn.start(queue: .global(qos: .utility))
            // Timeout
            Task {
                try? await Task.sleep(for: .seconds(10))
                if self.pendingQueries.removeValue(forKey: txID) != nil {
                    cont.resume(throwing: DHTError.timeout)
                }
            }
        }
    }

    private func sendPong(txID: String, conn: NWConnection) async {
        let resp: BencodeValue = .dictionary([
            "t": .string(Data(hexString: txID) ?? Data()),
            "y": .string("r".data(using: .utf8)!),
            "r": .dictionary(["id": .string(localID.data)])
        ])
        conn.send(content: BencodeEncoder.encode(resp), completion: .idempotent)
    }

    private func sendFindNodeResponse(txID: String, nodes: [DHTNodeInfo], conn: NWConnection) async {
        var compactNodes = Data()
        for node in nodes.prefix(8) {
            compactNodes.append(node.id.data)
            if let addr = IPv4Address(node.host) {
                compactNodes.append(addr.rawValue)
            }
            compactNodes.append(bigEndian: node.port)
        }
        let resp: BencodeValue = .dictionary([
            "t": .string(Data(hexString: txID) ?? Data()),
            "y": .string("r".data(using: .utf8)!),
            "r": .dictionary([
                "id": .string(localID.data),
                "nodes": .string(compactNodes)
            ])
        ])
        conn.send(content: BencodeEncoder.encode(resp), completion: .idempotent)
    }

    private func sendGetPeersResponse(txID: String, nodes: [DHTNodeInfo], conn: NWConnection) async {
        var compactNodes = Data()
        for node in nodes.prefix(8) {
            compactNodes.append(node.id.data)
            if let addr = IPv4Address(node.host) {
                compactNodes.append(addr.rawValue)
            }
            compactNodes.append(bigEndian: node.port)
        }
        let token = Data(UUID().uuidString.utf8.prefix(4))
        let resp: BencodeValue = .dictionary([
            "t": .string(Data(hexString: txID) ?? Data()),
            "y": .string("r".data(using: .utf8)!),
            "r": .dictionary([
                "id": .string(localID.data),
                "token": .string(token),
                "nodes": .string(compactNodes)
            ])
        ])
        conn.send(content: BencodeEncoder.encode(resp), completion: .idempotent)
    }

    private func randomTransactionID() -> Data {
        Data((0..<2).map { _ in UInt8.random(in: 0...255) })
    }

    var nodeCount: Int { Task { await routingTable.allNodes().count }.hashValue }

    enum DHTError: Error, Sendable {
        case timeout
        case errorResponse
    }
}

extension Data {
    mutating func append(bigEndian value: UInt16) {
        var v = value.bigEndian
        withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
