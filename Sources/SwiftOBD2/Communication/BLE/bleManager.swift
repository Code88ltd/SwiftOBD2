import Combine
import CoreBluetooth
import Foundation

public enum ConnectionState: Sendable {
    case disconnected
    case connecting
    case connectedToAdapter
    case connectedToVehicle
    case error

    public var description: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .connectedToAdapter: return "Connected to Adapter"
        case .connectedToVehicle: return "Connected to Vehicle"
        case .error: return "Error"
        }
    }

    public var isConnected: Bool {
        switch self {
        case .connectedToAdapter, .connectedToVehicle:
            return true
        default:
            return false
        }
    }
}

enum BLEConstants {
    static let defaultTimeout: TimeInterval = 3.0
    static let scanDuration: TimeInterval = 10.0
    static let connectionTimeout: TimeInterval = 10.0
    static let retryDelay: TimeInterval = 0.5
    static let maxBufferSize = 1024
    static let bluetoothPowerOnTimeout: TimeInterval = 30.0
    static let pollingInterval: UInt64 = 100_000_000
}

final class BLEManager: NSObject, CommProtocol, BLEPeripheralManagerDelegate {
    private let peripheralSubject = PassthroughSubject<CBPeripheral, Never>()

    static let RestoreIdentifierKey: String = "OBD2Adapter"

    @Published var connectionState: ConnectionState = .disconnected

    var connectionStatePublisher: Published<ConnectionState>.Publisher {
        $connectionState
    }

    public weak var obdDelegate: OBDServiceDelegate?

    private var centralManager: CBCentralManager!
    private var messageProcessor: BLEMessageProcessor!
    private var characteristicHandler: BLECharacteristicHandler!
    private var peripheralManager: BLEPeripheralManager!
    private var peripheralScanner: BLEPeripheralScanner!

    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()

        let bleQueue = DispatchQueue(label: "com.swiftobd2.ble", qos: .userInitiated)

        centralManager = CBCentralManager(
            delegate: self,
            queue: bleQueue,
            options: [
                CBCentralManagerOptionShowPowerAlertKey: true,
                CBCentralManagerOptionRestoreIdentifierKey: BLEManager.RestoreIdentifierKey
            ]
        )

        messageProcessor = BLEMessageProcessor()
        characteristicHandler = BLECharacteristicHandler(messageProcessor: messageProcessor)

        peripheralManager = BLEPeripheralManager(characteristicHandler: characteristicHandler)
        peripheralManager.delegate = self

        peripheralScanner = BLEPeripheralScanner()
    }

    deinit {
        cancellables.removeAll()
        disconnectPeripheral()
        obdDebug("BLEManager deinitialized", category: .bluetooth)
    }

    // MARK: - Public Async Helpers

    func scanForPeripherals(services: [CBUUID]?) async throws {
        try await waitForPoweredOn()
        startScanning(services)
    }

    func stopScanning() {
        stopScan()
    }

    func waitForFirstPeripheral(timeout: TimeInterval) async throws -> CBPeripheral {
        try await peripheralScanner.waitForFirstPeripheral(timeout: timeout)
    }

    // MARK: - Scanning

    func startScanning(_ serviceUUIDs: [CBUUID]?) {
        guard centralManager.state == .poweredOn else {
            obdWarning("Cannot start scanning - Bluetooth not powered on", category: .bluetooth)
            return
        }

        obdDebug(
            "Starting BLE scan for services: \(serviceUUIDs?.map { $0.uuidString } ?? ["All"])",
            category: .bluetooth
        )

        centralManager.scanForPeripherals(
            withServices: serviceUUIDs,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func stopScan() {
        if centralManager.isScanning {
            obdDebug("Stopping BLE scan", category: .bluetooth)
            centralManager.stopScan()
        }
    }

    // MARK: - Connection

    func connect(to peripheral: CBPeripheral) {
        let peripheralName = peripheral.name ?? "Unnamed"

        obdInfo("Attempting connection to peripheral: \(peripheralName)", category: .bluetooth)

        let oldState = connectionState
        connectionState = .connecting
        OBDLogger.shared.logConnectionChange(from: oldState, to: connectionState)

        DispatchQueue.main.async {
            self.obdDelegate?.connectionStateChanged(state: .connecting)
        }

        centralManager.connect(
            peripheral,
            options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true]
        )

        if centralManager.isScanning {
            centralManager.stopScan()
        }
    }

    func disconnectPeripheral() {
        guard let peripheral = peripheralManager.connectedPeripheral else {
            return
        }

        obdInfo(
            "Disconnecting peripheral: \(peripheral.name ?? "Unnamed")",
            category: .bluetooth
        )

        centralManager.cancelPeripheralConnection(peripheral)
        peripheralManager.setPeripheral(nil)
    }

    func connectAsync(timeout: TimeInterval, peripheral: CBPeripheral? = nil) async throws {
        try await waitForPoweredOn()

        if connectionState.isConnected {
            obdInfo("Already connected to peripheral", category: .bluetooth)
            return
        }

        let targetPeripheral: CBPeripheral

        if let peripheral {
            targetPeripheral = peripheral
        } else {
            startScanning(BLEPeripheralScanner.supportedServices)
            targetPeripheral = try await peripheralScanner.waitForFirstPeripheral(timeout: timeout)
        }

        connect(to: targetPeripheral)

        try await peripheralManager.waitForCharacteristicsSetup(timeout: timeout)
    }

    // MARK: - Sending

    func sendCommand(_ command: String, retries _: Int = 3) async throws -> [String] {
        guard let peripheral = peripheralManager.connectedPeripheral else {
            obdError("Missing peripheral or ECU characteristic", category: .bluetooth)
            throw BLEManagerError.missingPeripheralOrCharacteristic
        }

        obdDebug("Sending command: \(command)", category: .communication)

        do {
            try await characteristicHandler.writeCommand(command, to: peripheral)
            let response = try await messageProcessor.waitForResponse(timeout: BLEConstants.defaultTimeout)
            obdDebug(
                "Command response: \(response.joined(separator: " | "))",
                category: .communication
            )
            return response
        } catch {
            obdError(
                "Command failed: \(command) - \(error.localizedDescription)",
                category: .communication
            )
            throw error
        }
    }

    // MARK: - Compatibility Scan

    func scanForPeripherals() async throws {
        startScanning(nil)
        try await Task.sleep(nanoseconds: UInt64(BLEConstants.scanDuration * 1_000_000_000))
        stopScan()
    }

    // MARK: - BLEPeripheralManagerDelegate

    func peripheralManager(_ manager: BLEPeripheralManager, didSetupCharacteristics peripheral: CBPeripheral) {
        let oldState = connectionState
        connectionState = .connectedToAdapter
        OBDLogger.shared.logConnectionChange(from: oldState, to: connectionState)

        DispatchQueue.main.async {
            self.obdDelegate?.connectionStateChanged(state: .connectedToAdapter)
        }

        obdInfo("Characteristics setup complete, connected to adapter", category: .bluetooth)
    }

    // MARK: - Bluetooth State

    func waitForPoweredOn() async throws {
        let maxWaitTime = BLEConstants.bluetoothPowerOnTimeout
        let startTime = CFAbsoluteTimeGetCurrent()

        while centralManager.state != .poweredOn {
            if CFAbsoluteTimeGetCurrent() - startTime > maxWaitTime {
                obdError(
                    "Bluetooth failed to power on within \(maxWaitTime) seconds",
                    category: .bluetooth
                )
                throw BLEManagerError.timeout
            }

            switch centralManager.state {
            case .unsupported:
                throw BLEManagerError.unsupported
            case .unauthorized:
                throw BLEManagerError.unauthorized
            case .poweredOff:
                obdWarning("Bluetooth is powered off - waiting...", category: .bluetooth)
            case .resetting:
                obdDebug("Bluetooth is resetting - waiting...", category: .bluetooth)
            default:
                break
            }

            try await Task.sleep(nanoseconds: BLEConstants.pollingInterval)
        }

        obdDebug("Bluetooth powered on successfully", category: .bluetooth)
    }

    private func resetConfigure() {
        characteristicHandler.reset()
        peripheralManager.setPeripheral(nil)

        let oldState = connectionState
        connectionState = .disconnected

        if oldState != connectionState {
            OBDLogger.shared.logConnectionChange(from: oldState, to: connectionState)

            DispatchQueue.main.async {
                self.obdDelegate?.connectionStateChanged(state: .disconnected)
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            centralManagerDidPowerOn()

        case .poweredOff:
            obdWarning("Bluetooth powered off", category: .bluetooth)
            peripheralManager.setPeripheral(nil)

            let oldState = connectionState
            connectionState = .disconnected
            OBDLogger.shared.logConnectionChange(from: oldState, to: connectionState)

            DispatchQueue.main.async {
                self.obdDelegate?.connectionStateChanged(state: .disconnected)
            }

        case .unsupported:
            obdError("Device does not support Bluetooth Low Energy", category: .bluetooth)

        case .unauthorized:
            obdError("App not authorized to use Bluetooth Low Energy", category: .bluetooth)

        case .resetting:
            obdWarning("Bluetooth is resetting", category: .bluetooth)

        default:
            obdError(
                "Bluetooth in unexpected state: \(central.state.rawValue)",
                category: .bluetooth
            )

            let oldState = connectionState
            connectionState = .error
            OBDLogger.shared.logConnectionChange(from: oldState, to: connectionState)

            DispatchQueue.main.async {
                self.obdDelegate?.connectionStateChanged(state: .error)
            }
        }
    }

    private func centralManagerDidPowerOn() {
        guard let device = peripheralManager.connectedPeripheral else {
            startScanning(BLEPeripheralScanner.supportedServices)
            return
        }

        connect(to: device)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        peripheralScanner.addDiscoveredPeripheral(
            peripheral,
            advertisementData: advertisementData,
            rssi: RSSI
        )
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        obdInfo("Connected to peripheral: \(peripheral.name ?? "Unnamed")", category: .bluetooth)

        peripheralManager.setPeripheral(peripheral)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        let peripheralName = peripheral.name ?? "Unnamed"
        let errorMsg = error?.localizedDescription ?? "Unknown error"

        obdError(
            "Connection failed to peripheral: \(peripheralName) - \(errorMsg)",
            category: .bluetooth
        )

        peripheralManager.setPeripheral(nil)

        let oldState = connectionState
        connectionState = .error
        OBDLogger.shared.logConnectionChange(from: oldState, to: connectionState)

        DispatchQueue.main.async {
            self.obdDelegate?.connectionStateChanged(state: .error)
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let peripheralName = peripheral.name ?? "Unnamed"

        if let error {
            obdWarning(
                "Unexpected disconnection from \(peripheralName): \(error.localizedDescription)",
                category: .bluetooth
            )
        } else {
            obdInfo("Disconnected from peripheral: \(peripheralName)", category: .bluetooth)
        }

        resetConfigure()
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let peripheral = peripherals.first {
            obdDebug(
                "Restoring peripheral: \(peripheral.name ?? "Unnamed")",
                category: .bluetooth
            )

            peripheralManager.setPeripheral(peripheral)
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        connectionEventDidOccur event: CBConnectionEvent,
        for peripheral: CBPeripheral
    ) {
        obdError(
            "Unexpected connection event: \(event.rawValue) for \(peripheral.name ?? "Unnamed")",
            category: .bluetooth
        )
    }
}

enum BLEManagerError: Error, CustomStringConvertible {
    case missingPeripheralOrCharacteristic
    case unknownCharacteristic
    case scanTimeout
    case sendMessageTimeout
    case stringConversionFailed
    case noData
    case incorrectDataConversion
    case peripheralNotConnected
    case sendingMessagesInProgress
    case timeout
    case peripheralNotFound
    case unknownError
    case unsupported
    case unauthorized

    public var description: String {
        switch self {
        case .missingPeripheralOrCharacteristic:
            return "Error: Device not connected. Make sure the device is correctly connected."
        case .scanTimeout:
            return "Error: Scan timed out. Please try to scan again or check the device's Bluetooth connection."
        case .sendMessageTimeout:
            return "Error: Send message timed out. Please try to send the message again or check the device's Bluetooth connection."
        case .stringConversionFailed:
            return "Error: Failed to convert string. Please make sure the string is in the correct format."
        case .noData:
            return "Error: No Data"
        case .unknownCharacteristic:
            return "Error: Unknown characteristic"
        case .incorrectDataConversion:
            return "Error: Incorrect data conversion"
        case .peripheralNotConnected:
            return "Error: Peripheral not connected"
        case .sendingMessagesInProgress:
            return "Error: Sending messages in progress"
        case .timeout:
            return "Error: Timeout"
        case .peripheralNotFound:
            return "Error: Peripheral not found"
        case .unknownError:
            return "Unknown Error"
        case .unsupported:
            return "Error: Device does not support Bluetooth Low Energy"
        case .unauthorized:
            return "Error: App not authorized to use Bluetooth Low Energy"
        }
    }
}
