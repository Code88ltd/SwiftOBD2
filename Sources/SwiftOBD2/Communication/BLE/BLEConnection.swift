import Combine
import CoreBluetooth
import Foundation
import OSLog

protocol BLEConnectionProtocol {
    var connectionState: ConnectionState { get }
    var connectedPeripheral: CBPeripheral? { get }
    var connectedPeripheralPublisher: AnyPublisher<CBPeripheral?, Never> { get }
    var connectionStatePublisher: AnyPublisher<ConnectionState, Never> { get }

    func connect(to peripheral: CBPeripheral, timeout: TimeInterval) async throws
    func disconnect()
    func isReady() -> Bool
}

final class BLEConnection: NSObject, BLEConnectionProtocol {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.swiftobd2.app",
        category: "BLEConnection"
    )

    private weak var centralManager: CBCentralManager?

    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var connectedPeripheral: CBPeripheral?

    private var connectionCompletion: ((CBPeripheral?, Error?) -> Void)?
    private var connectionTimeout: Task<Void, Never>?

    var connectionStatePublisher: AnyPublisher<ConnectionState, Never> {
        $connectionState.eraseToAnyPublisher()
    }

    var connectedPeripheralPublisher: AnyPublisher<CBPeripheral?, Never> {
        $connectedPeripheral.eraseToAnyPublisher()
    }

    static let cxService = CBUUID(string: "0000FFF0-0000-1000-8000-00805F9B34FB")

    static let defaultServices: [CBUUID] = [
        BLEConnection.cxService,
        CBUUID(string: "FFE0"),
        CBUUID(string: "18F0"),
        CBUUID(string: "FFF0"),
        CBUUID(string: "FFF1")
    ]

    init(centralManager: CBCentralManager) {
        self.centralManager = centralManager
        super.init()
        logger.debug("BLEConnection initialized")
    }

    func connect(to peripheral: CBPeripheral, timeout: TimeInterval = 10.0) async throws {
        guard let centralManager else {
            throw BLEConnectionError.centralManagerNotAvailable
        }

        guard centralManager.state == .poweredOn else {
            throw BLEConnectionError.bluetoothNotPoweredOn
        }

        guard connectionState == .disconnected else {
            throw BLEConnectionError.alreadyConnected
        }

        logger.info("Attempting to connect to peripheral: \(peripheral.name ?? peripheral.identifier.uuidString), timeout: \(timeout)s")

        connectionState = .connecting

        return try await withTimeout(
            seconds: timeout,
            timeoutError: BLEConnectionError.connectionTimeout,
            onTimeout: { [weak self] in
                self?.logger.error("BLE connection timed out after \(timeout)s")
                centralManager.cancelPeripheralConnection(peripheral)
                self?.resetConnectionState()
            },
            operation: {
                try await withCheckedThrowingContinuation { continuation in
                    var hasResumed = false

                    self.connectionCompletion = { [weak self] connectedPeripheral, error in
                        guard !hasResumed else { return }
                        hasResumed = true

                        self?.connectionCompletion = nil
                        self?.connectionTimeout?.cancel()
                        self?.connectionTimeout = nil

                        if let connectedPeripheral {
                            self?.logger.info("BLE adapter connected: \(connectedPeripheral.name ?? connectedPeripheral.identifier.uuidString)")
                            continuation.resume(returning: ())
                        } else {
                            self?.resetConnectionState()
                            continuation.resume(throwing: error ?? BLEConnectionError.connectionFailed)
                        }
                    }

                    /*
                     Important:
                     Do NOT set peripheral.delegate here.

                     BLEPeripheralManager owns CBPeripheralDelegate because it handles:
                     - service discovery
                     - characteristic discovery
                     - notification setup
                     - RX data
                     - PID response forwarding

                     Setting peripheral.delegate here would steal updates from BLEPeripheralManager
                     and stop live PID dashboard updates.
                     */

                    centralManager.connect(peripheral, options: [
                        CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
                        CBConnectPeripheralOptionNotifyOnConnectionKey: true
                    ])

                    if centralManager.isScanning {
                        centralManager.stopScan()
                        self.logger.debug("Stopped scanning before connection")
                    }
                }
            }
        )
    }

    func disconnect() {
        guard let peripheral = connectedPeripheral else {
            logger.debug("No BLE peripheral connected")
            return
        }

        logger.info("Disconnecting BLE peripheral: \(peripheral.name ?? peripheral.identifier.uuidString)")
        centralManager?.cancelPeripheralConnection(peripheral)
    }

    func isReady() -> Bool {
        connectionState == .connectedToAdapter && connectedPeripheral != nil
    }

    func handleDidConnect(_ peripheral: CBPeripheral) {
        logger.info("Connected to BLE peripheral: \(peripheral.name ?? peripheral.identifier.uuidString)")

        connectedPeripheral = peripheral
        connectionState = .connectedToAdapter

        UserDefaults.standard.set(
            peripheral.identifier.uuidString,
            forKey: "lastConnectedPeripheral"
        )

        connectionCompletion?(peripheral, nil)
    }

    func handleDidDisconnect(_ peripheral: CBPeripheral, error: Error?) {
        if let error {
            logger.warning("Disconnected from BLE peripheral with error: \(error.localizedDescription)")
        } else {
            logger.info("Disconnected from BLE peripheral: \(peripheral.name ?? peripheral.identifier.uuidString)")
        }

        resetConnectionState()
    }

    func handleDidFailToConnect(_ peripheral: CBPeripheral, error: Error?) {
        let message = error?.localizedDescription ?? "Unknown error"
        logger.error("Failed to connect to BLE peripheral \(peripheral.name ?? peripheral.identifier.uuidString): \(message)")

        connectionCompletion?(nil, error ?? BLEConnectionError.connectionFailed)
        resetConnectionState()
    }

    private func resetConnectionState() {
        connectedPeripheral = nil
        connectionState = .disconnected
        connectionCompletion = nil
        connectionTimeout?.cancel()
        connectionTimeout = nil
    }

    deinit {
        disconnect()
        connectionTimeout?.cancel()
        logger.debug("BLEConnection deinitialized")
    }
}

enum BLEConnectionError: Error, LocalizedError, Equatable {
    case centralManagerNotAvailable
    case bluetoothNotPoweredOn
    case alreadyConnected
    case connectionFailed
    case connectionTimeout
    case noServicesFound
    case requiredCharacteristicsNotFound

    var errorDescription: String? {
        switch self {
        case .centralManagerNotAvailable:
            return "Bluetooth Central Manager is not available"
        case .bluetoothNotPoweredOn:
            return "Bluetooth is not powered on"
        case .alreadyConnected:
            return "Already connected to a peripheral"
        case .connectionFailed:
            return "Failed to connect to BLE peripheral"
        case .connectionTimeout:
            return "Connection attempt timed out"
        case .noServicesFound:
            return "No compatible services found on peripheral"
        case .requiredCharacteristicsNotFound:
            return "Required characteristics not found on peripheral"
        }
    }
}
