import Foundation
import Network
import os.log

// MARK: - Peer Connection State

enum PeerConnectionState: Sendable {
    case connecting
    case handshaking
    case active
    case disconnected
    case failed(Error)
}

// MARK: - Peer Connection

actor PeerConnection {
    let peerAddress: String
    let port: UInt16
    let infoHash: Data
    let localPeerID: Data

    private var connection: NWConnection?
    private var state: PeerConnectionState = .connecting
    private let logger = Logger(subsystem: "com.bitflow.engine", category: "PeerConnection")

    // Protocol state
    private(set) var remotePeerID: Data?
    private(set) var isChoked: Bool = true           // we are choked by remote
    private(set) var isInterested: Bool = false       // we are interested in remote
    private(set) var remoteChoked: Bool = true        // remote is choked by us
    private(set) var remoteInterested: Bool = false   // remote is interested in us
    private(set) var remoteBitfield: Bitfield?
    private(set) var remoteExtensions: ExtensionHandshake?
    private(set) var extensionIDs: [String: UInt8] = [:]

    // Performance
    private(set) var downloadSpeed: Double = 0
    private(set) var uploadSpeed: Double = 0
    private(set) var latency: TimeInterval = 0
    private(set) var bytesDownloaded: Int64 = 0
    private(set) var bytesUploaded: Int64 = 0

    // Pipeline
    private var inflightRequests: Set<BlockRequest> = []
    private let maxInflight = 16

    // Callbacks (weak to avoid retain cycles through actor)
    var onPieceReceived: (@Sendable (Int, Int, Data) async -> Void)?
    var onHaveReceived: (@Sendable (Int) -> Void)?
    var onBitfieldReceived: (@Sendable (Bitfield) -> Void)?
    var onDisconnected: (@Sendable (String) -> Void)?
    var onPEXReceived: (@Sendable ([PEXMessage.PeerInfo]) -> Void)?
    var onPortReceived: (@Sendable (UInt16) -> Void)?

    private var receiveBuffer = Data()
    private var speedTimer: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var connectTime: Date = .now
    private var lastReceivedBytes: Int64 = 0
    private var lastUploadedBytes: Int64 = 0

    init(address: String, port: UInt16, infoHash: Data, localPeerID: Data) {
        self.peerAddress = address
        self.port = port
        self.infoHash = infoHash
        self.localPeerID = localPeerID
    }

    deinit {
        speedTimer?.cancel()
        keepAliveTask?.cancel()
    }

    // MARK: - Connect

    func connect() async {
        let host = NWEndpoint.Host(peerAddress)
        let portEndpoint = NWEndpoint.Port(rawValue: port) ?? .http

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        connection = NWConnection(host: host, port: portEndpoint, using: params)
        state = .connecting

        connection?.stateUpdateHandler = { [weak self] newState in
            Task { [weak self] in
                await self?.handleConnectionState(newState)
            }
        }

        connection?.start(queue: .global(qos: .utility))
        startSpeedTracking()
    }

    func connectIncoming(_ conn: NWConnection) async {
        connection = conn
        state = .handshaking
        conn.stateUpdateHandler = { [weak self] newState in
            Task { [weak self] in
                await self?.handleConnectionState(newState)
            }
        }
        conn.start(queue: .global(qos: .utility))
        await sendHandshake()
        await receiveLoop()
    }

    // MARK: - State Handling

    private func handleConnectionState(_ state: NWConnection.State) async {
        switch state {
        case .ready:
            self.state = .handshaking
            await sendHandshake()
            await receiveLoop()
        case .failed(let error):
            self.state = .failed(error)
            logger.debug("Connection to \(self.peerAddress):\(self.port) failed: \(error)")
            onDisconnected?(peerID)
        case .cancelled:
            self.state = .disconnected
            onDisconnected?(peerID)
        default:
            break
        }
    }

    var peerID: String { "\(peerAddress):\(port)" }

    // MARK: - Handshake

    private func sendHandshake() async {
        let hs = Handshake.create(
            infoHash: infoHash,
            peerID: localPeerID,
            supportsDHT: true,
            supportsExtensions: true
        )
        await send(hs)
    }

    private func handleHandshake(_ data: Data) async -> Bool {
        guard data.count >= Handshake.length else { return false }
        do {
            let hs = try Handshake.parse(data)
            guard hs.infoHash == infoHash else {
                logger.warning("Info hash mismatch from \(self.peerAddress)")
                disconnect()
                return false
            }
            self.remotePeerID = hs.peerID

            if hs.supportsExtensionProtocol {
                await sendExtensionHandshake()
            }

            state = .active
            startKeepalive()
            return true
        } catch {
            logger.warning("Handshake parse error: \(error)")
            disconnect()
            return false
        }
    }

    // MARK: - Extension Protocol

    private func sendExtensionHandshake() async {
        var hs = ExtensionHandshake()
        hs.extensions[ExtensionHandshake.utMetadata] = 1
        hs.extensions[ExtensionHandshake.utPex] = 2
        hs.clientVersion = "BitFlow/1.0"
        hs.requestQueue = 250

        let payload = hs.encode()
        let msg = PeerMessage.extended(id: 0, payload: payload)
        await send(msg.encode())
    }

    private func handleExtendedMessage(id: UInt8, payload: Data) async {
        if id == 0 {
            // Handshake
            if let hs = try? ExtensionHandshake.decode(payload) {
                self.remoteExtensions = hs
                for (name, msgID) in hs.extensions {
                    extensionIDs[name] = UInt8(msgID)
                }
            }
        } else if id == extensionIDs[ExtensionHandshake.utPex] {
            if let pex = try? PEXMessage.decode(payload) {
                onPEXReceived?(pex.added)
            }
        } else if id == extensionIDs[ExtensionHandshake.utMetadata] {
            // handled by MetadataFetcher
        }
    }

    // MARK: - Receive Loop

    private func receiveLoop() async {
        guard let conn = connection else { return }

        // First receive handshake (68 bytes)
        if state == .handshaking {
            if let data = await receive(minLength: Handshake.length, maxLength: Handshake.length, conn: conn) {
                let handshakeOK = await handleHandshake(data)
                guard handshakeOK else { return }
            } else {
                disconnect()
                return
            }
        }

        while state == .active {
            // Read length prefix (4 bytes)
            guard let lenData = await receive(minLength: 4, maxLength: 4, conn: conn) else { break }
            let length = lenData.readUInt32(at: 0)

            if length == 0 {
                // Keepalive
                continue
            }

            // Read message body
            guard let body = await receive(minLength: Int(length), maxLength: Int(length), conn: conn) else { break }
            let id = body[body.startIndex]
            let payload = body.dropFirst()

            do {
                let msg = try PeerMessage.decode(length: length, id: id, payload: Data(payload))
                await handleMessage(msg)
            } catch PeerMessage.ParseError.unknownMessage(let mid) {
                logger.debug("Unknown message \(mid) — ignoring")
            } catch {
                logger.warning("Message parse error: \(error)")
            }
        }

        onDisconnected?(peerID)
    }

    private func receive(minLength: Int, maxLength: Int, conn: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            conn.receive(minimumIncompleteLength: minLength, maximumLength: maxLength) { data, _, isComplete, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Message Handling

    private func handleMessage(_ msg: PeerMessage) async {
        switch msg {
        case .keepAlive: break

        case .choke:
            isChoked = true

        case .unchoke:
            isChoked = false

        case .interested:
            remoteInterested = true

        case .notInterested:
            remoteInterested = false

        case .have(let index):
            onHaveReceived?(index)

        case .bitfield(let data):
            let bf = Bitfield(data: data, size: remoteBitfield?.size ?? data.count * 8)
            remoteBitfield = bf
            onBitfieldReceived?(bf)

        case .piece(let index, let begin, let block):
            bytesDownloaded += Int64(block.count)
            inflightRequests.remove(BlockRequest(pieceIndex: index, blockOffset: begin, blockLength: block.count))
            await onPieceReceived?(index, begin, block)

        case .request(let index, let begin, let length):
            if !remoteChoked {
                // Serve the block
                await serveBlock(index: index, begin: begin, length: length)
            }

        case .cancel(let index, let begin, let length):
            inflightRequests.remove(BlockRequest(pieceIndex: index, blockOffset: begin, blockLength: length))

        case .port(let port):
            onPortReceived?(port)

        case .extended(let id, let payload):
            await handleExtendedMessage(id: id, payload: payload)
        }
    }

    // MARK: - Sending

    func sendInterested() async {
        isInterested = true
        await send(PeerMessage.interested.encode())
    }

    func sendNotInterested() async {
        isInterested = false
        await send(PeerMessage.notInterested.encode())
    }

    func sendUnchoke() async {
        remoteChoked = false
        await send(PeerMessage.unchoke.encode())
    }

    func sendChoke() async {
        remoteChoked = true
        await send(PeerMessage.choke.encode())
    }

    func sendHave(pieceIndex: Int) async {
        await send(PeerMessage.have(pieceIndex: pieceIndex).encode())
    }

    func sendBitfield(_ bitfield: Bitfield) async {
        await send(PeerMessage.bitfield(data: bitfield.data).encode())
    }

    func requestBlock(_ req: BlockRequest) async {
        guard !isChoked, inflightRequests.count < maxInflight else { return }
        inflightRequests.insert(req)
        let msg = PeerMessage.request(index: req.pieceIndex, begin: req.blockOffset, length: req.blockLength)
        await send(msg.encode())
    }

    func cancelBlock(_ req: BlockRequest) async {
        inflightRequests.remove(req)
        let msg = PeerMessage.cancel(index: req.pieceIndex, begin: req.blockOffset, length: req.blockLength)
        await send(msg.encode())
    }

    private func serveBlock(index: Int, begin: Int, length: Int) async {
        // Disk read would happen here — delegated to StorageManager
        bytesUploaded += Int64(length)
    }

    private func send(_ data: Data) async {
        guard let conn = connection else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            conn.send(content: data, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }

    // MARK: - Keepalive

    private func startKeepalive() {
        keepAliveTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(90))
                await self?.send(PeerMessage.keepAlive.encode())
            }
        }
    }

    // MARK: - Speed Tracking

    private func startSpeedTracking() {
        speedTimer = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.updateSpeeds()
            }
        }
    }

    private func updateSpeeds() {
        let dl = bytesDownloaded - lastReceivedBytes
        let ul = bytesUploaded - lastUploadedBytes
        downloadSpeed = Double(dl)
        uploadSpeed = Double(ul)
        lastReceivedBytes = bytesDownloaded
        lastUploadedBytes = bytesUploaded
    }

    // MARK: - Disconnect

    func disconnect() {
        state = .disconnected
        connection?.cancel()
        connection = nil
        speedTimer?.cancel()
        keepAliveTask?.cancel()
    }

    var isActive: Bool {
        if case .active = state { return true }
        return false
    }

    var canRequest: Bool { isActive && !isChoked && isInterested }
    var inflightCount: Int { inflightRequests.count }
    var hasCapacity: Bool { inflightRequests.count < maxInflight }
}
