import Combine
import ExternalAccessory
import Foundation
import OSLog

/// Protocol for ExternalAccessory connection operations (BT Classic / iAP)
protocol EAConnectionProtocol {
    var connectionState: ConnectionState { get }
    var connectedAccessory: EAAccessory? { get }
    var connectedAccessoryPublisher: AnyPublisher<EAAccessory?, Never> { get }
    var connectionStatePublisher: AnyPublisher<ConnectionState, Never> { get }

    func connect(timeout: TimeInterval) async throws
    func disconnect()
    func isReady() -> Bool

    // Streams for IO
    var inputStream: InputStream? { get }
    var outputStream: OutputStream? { get }
}

final class EAConnection: NSObject, EAConnectionProtocol {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.swiftobd2.app", category: "EAConnection")

    private let protocolString: String

    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var connectedAccessory: EAAccessory?

    private(set) var session: EASession?
    private(set) var inputStream: InputStream?
    private(set) var outputStream: OutputStream?

    var connectionStatePublisher: AnyPublisher<ConnectionState, Never> {
        $connectionState.eraseToAnyPublisher()
    }

    var connectedAccessoryPublisher: AnyPublisher<EAAccessory?, Never> {
        $connectedAccessory.eraseToAnyPublisher()
    }

    init(protocolString: String = "com.obdlink") {
        self.protocolString = protocolString
        super.init()

        EAAccessoryManager.shared().registerForLocalNotifications()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(accessoryDidConnect(_:)),
                                               name: .EAAccessoryDidConnect,
                                               object: nil)

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(accessoryDidDisconnect(_:)),
                                               name: .EAAccessoryDidDisconnect,
                                               object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        EAAccessoryManager.shared().unregisterForLocalNotifications()
        disconnect()
    }

    func connect(timeout: TimeInterval = 10.0) async throws {
        guard connectionState == .disconnected else {
            throw EAConnectionError.alreadyConnected
        }

        connectionState = .connecting
        logger.info("Attempting EA connect with timeout: \(timeout, privacy: .public)s")

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try openSessionIfAvailable() {
                connectionState = .connectedToAdapter
                return
            }
            try await Task.sleep(nanoseconds: 250_000_000) // 250ms
        }

        connectionState = .error
        throw EAConnectionError.noAccessoryFound(protocolString: protocolString)
    }

    func disconnect() {
        logger.info("Disconnecting EA session")
        inputStream?.close()
        outputStream?.close()
        inputStream = nil
        outputStream = nil
        session = nil
        connectedAccessory = nil
        connectionState = .disconnected
    }

    func isReady() -> Bool {
        connectionState == .connectedToAdapter && inputStream != nil && outputStream != nil
    }

    // MARK: - Internal

    private func openSessionIfAvailable() throws -> Bool {
        let accessories = EAAccessoryManager.shared().connectedAccessories
        guard let acc = accessories.first(where: { $0.protocolStrings.contains(protocolString) }) else {
            return false
        }

        logger.info("Found EA accessory: \(acc.name, privacy: .public)")
        connectedAccessory = acc

        guard let sess = EASession(accessory: acc, forProtocol: protocolString) else {
            throw EAConnectionError.sessionOpenFailed
        }

        session = sess
        inputStream = sess.inputStream
        outputStream = sess.outputStream

        inputStream?.open()
        outputStream?.open()

        return true
    }

    @objc private func accessoryDidConnect(_ note: Notification) {
        guard let acc = note.userInfo?[EAAccessoryKey] as? EAAccessory else { return }
        guard acc.protocolStrings.contains(protocolString) else { return }

        logger.info("EA accessory connected: \(acc.name, privacy: .public)")
        // Optional: auto-open session if app is running
        if connectionState == .disconnected {
            Task { try? await connect(timeout: 3.0) }
        }
    }

    @objc private func accessoryDidDisconnect(_ note: Notification) {
        guard let acc = note.userInfo?[EAAccessoryKey] as? EAAccessory else { return }
        if acc.connectionID == connectedAccessory?.connectionID {
            logger.info("EA accessory disconnected: \(acc.name, privacy: .public)")
            disconnect()
        }
    }
}

enum EAConnectionError: Error, LocalizedError, Equatable {
    case alreadyConnected
    case noAccessoryFound(protocolString: String)
    case sessionOpenFailed

    var errorDescription: String? {
        switch self {
        case .alreadyConnected:
            return "Already connected to an ExternalAccessory session"
        case .noAccessoryFound(let p):
            return "No connected ExternalAccessory found for protocol \(p)"
        case .sessionOpenFailed:
            return "Failed to open EASession"
        }
    }
}
