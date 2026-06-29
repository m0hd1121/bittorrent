import Network
import Combine
import os.log

// MARK: - Network Monitor

@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published private(set) var isConnected: Bool = false
    @Published private(set) var connectionType: ConnectionType = .none
    @Published private(set) var isExpensive: Bool = false      // cellular
    @Published private(set) var isConstrained: Bool = false    // Low Data Mode
    @Published private(set) var isVPN: Bool = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.bitflow.networkmonitor")
    private let logger = Logger(subsystem: "com.bitflow.app", category: "NetworkMonitor")

    enum ConnectionType: Sendable {
        case none, wifi, cellular, wiredEthernet, other
    }

    private init() {
        start()
    }

    private func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.update(path)
            }
        }
        monitor.start(queue: queue)
    }

    private func update(_ path: NWPath) {
        isConnected = path.status == .satisfied
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained

        if path.usesInterfaceType(.wifi) {
            connectionType = .wifi
        } else if path.usesInterfaceType(.cellular) {
            connectionType = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            connectionType = .wiredEthernet
        } else if path.status == .satisfied {
            connectionType = .other
        } else {
            connectionType = .none
        }

        // Heuristic VPN detection: connected but using tunnel/other interface
        isVPN = path.status == .satisfied &&
            !path.usesInterfaceType(.wifi) &&
            !path.usesInterfaceType(.cellular) &&
            !path.usesInterfaceType(.wiredEthernet) &&
            !path.usesInterfaceType(.loopback)

        logger.info("Network: \(String(describing: self.connectionType)), expensive: \(self.isExpensive), constrained: \(self.isConstrained)")

        // Notify engine to adapt to network change
        if !isConnected {
            Task { await TorrentEngine.shared.pauseAll() }
        }
    }

    var shouldThrottle: Bool { isConstrained || isExpensive }
    var isWiFi: Bool { connectionType == .wifi }

    deinit { monitor.cancel() }
}
