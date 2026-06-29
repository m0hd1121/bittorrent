import Foundation
import Network
import os.log

// BEP 14 - Local Service Discovery

actor LocalServiceDiscovery {
    private static let multicastAddress = "239.192.152.143"
    private static let port: UInt16 = 6771
    private static let announceInterval: TimeInterval = 5 * 60  // 5 minutes

    private let localPeerID: Data
    private var activeInfoHashes: Set<String> = []
    private var announceTask: Task<Void, Never>?
    private var listenConnection: NWConnection?
    private let logger = Logger(subsystem: "com.bitflow.engine", category: "LSD")

    var onPeersFound: (@Sendable (String, [PeerInfo]) -> Void)?  // infoHash hex -> peers

    init(localPeerID: Data) {
        self.localPeerID = localPeerID
    }

    func start(infoHash: String) {
        activeInfoHashes.insert(infoHash)
        if announceTask == nil {
            startAnnouncing()
            startListening()
        }
    }

    func stop(infoHash: String) {
        activeInfoHashes.remove(infoHash)
        if activeInfoHashes.isEmpty {
            announceTask?.cancel()
            announceTask = nil
            listenConnection?.cancel()
            listenConnection = nil
        }
    }

    private func startAnnouncing() {
        announceTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                await self?.sendAnnouncements()
                try? await Task.sleep(for: .seconds(Self.announceInterval))
            }
        }
    }

    private func sendAnnouncements() async {
        for infoHash in activeInfoHashes {
            await sendAnnounce(infoHash: infoHash)
        }
    }

    private func sendAnnounce(infoHash: String) async {
        let cookie = String(format: "%08x", UInt32.random(in: 0..<UInt32.max))
        let port = 6881  // Our listen port
        let message = """
        BT-SEARCH * HTTP/1.1\r
        Host: \(Self.multicastAddress):\(Self.port)\r
        Port: \(port)\r
        Infohash: \(infoHash)\r
        cookie: \(cookie)\r
        \r
        \r

        """

        guard let data = message.data(using: .utf8) else { return }

        let conn = NWConnection(
            host: NWEndpoint.Host(Self.multicastAddress),
            port: NWEndpoint.Port(rawValue: Self.port)!,
            using: .udp
        )
        conn.stateUpdateHandler = { state in
            if case .ready = state {
                conn.send(content: data, completion: .contentProcessed { _ in
                    conn.cancel()
                })
            }
        }
        conn.start(queue: .global(qos: .background))
    }

    private func startListening() {
        // Listen for LSD announcements from other peers on the local network
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        let conn = NWConnection(
            host: NWEndpoint.Host(Self.multicastAddress),
            port: NWEndpoint.Port(rawValue: Self.port)!,
            using: params
        )

        listenConnection = conn

        func receiveNext() {
            conn.receiveMessage { [weak self] data, context, _, error in
                if let data {
                    Task { [weak self] in
                        await self?.handleMessage(data, context: context)
                    }
                }
                if error == nil { receiveNext() }
            }
        }

        conn.stateUpdateHandler = { state in
            if case .ready = state { receiveNext() }
        }
        conn.start(queue: .global(qos: .utility))
    }

    private func handleMessage(_ data: Data, context: NWConnection.ContentContext?) async {
        guard let message = String(data: data, encoding: .utf8) else { return }

        // Parse HTTP-like LSD message
        var port: UInt16?
        var infoHash: String?

        for line in message.components(separatedBy: "\r\n") {
            let parts = line.components(separatedBy: ": ")
            if parts.count == 2 {
                switch parts[0] {
                case "Port":
                    port = UInt16(parts[1].trimmingCharacters(in: .whitespaces))
                case "Infohash":
                    infoHash = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
                default: break
                }
            }
        }

        guard let port, let infoHash, activeInfoHashes.contains(infoHash) else { return }

        // Get source IP from connection context
        if let sourceAddr = context?.localAddress {
            var host = "127.0.0.1"
            if case .hostPort(let h, _) = sourceAddr {
                host = "\(h)"
            }
            let peer = PeerInfo(host: host, port: port, source: .lsd, lastSeen: .now, failCount: 0)
            logger.info("LSD found peer \(host):\(port) for \(infoHash)")
            onPeersFound?(infoHash, [peer])
        }
    }
}
