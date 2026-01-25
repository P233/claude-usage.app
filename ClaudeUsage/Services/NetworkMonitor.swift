import Foundation
import Network
import Combine
import os.log

private let logger = Logger(subsystem: Constants.App.bundleIdentifier, category: "NetworkMonitor")

/// Monitors network connectivity status using NWPathMonitor.
/// Publishes connection state changes that can be observed by other components.
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    /// Whether the device currently has network connectivity
    @Published private(set) var isConnected: Bool = true

    /// The type of network connection (wifi, cellular, etc.)
    @Published private(set) var connectionType: ConnectionType = .unknown

    enum ConnectionType: String {
        case wifi
        case cellular
        case wiredEthernet
        case other
        case unknown
    }

    private let monitor: NWPathMonitor
    private let monitorQueue = DispatchQueue(label: "com.claudeusage.app.networkmonitor")

    private init() {
        monitor = NWPathMonitor()
        startMonitoring()
    }

    deinit {
        // NWPathMonitor.cancel() is thread-safe and can be called from any context
        monitor.cancel()
    }

    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self = self else { return }

                let wasConnected = self.isConnected
                self.isConnected = path.status == .satisfied
                self.connectionType = self.getConnectionType(from: path)

                if wasConnected != self.isConnected {
                    if self.isConnected {
                        logger.info("Network connected via \(self.connectionType.rawValue)")
                    } else {
                        logger.warning("Network disconnected")
                    }
                }
            }
        }

        monitor.start(queue: monitorQueue)
        logger.debug("Network monitoring started")
    }

    private func getConnectionType(from path: NWPath) -> ConnectionType {
        if path.usesInterfaceType(.wifi) {
            return .wifi
        } else if path.usesInterfaceType(.cellular) {
            return .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            return .wiredEthernet
        } else if path.status == .satisfied {
            return .other
        } else {
            return .unknown
        }
    }
}
