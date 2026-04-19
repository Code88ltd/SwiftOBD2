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

enum BLEAdapterProfile: String {
    case obdLinkCX
    case elmFFE0
    case vgate18F0
    case generic
}

class BLEConnection: NSObject, BLEConnectionProtocol {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.swiftobd2.app",
        category: "BLEConnection"
    )

    private weak var centralManager: CBCentralManager?
    private let supportedServices: [CBUUID]

    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var connectedPeripheral: CBPeripheral?

    var ecuReadCharacteristic: CBCharacteristic?
    var ecuWriteCharacteristic: CBCharacteristic?

    private var adapterProfile: BLEAdapterProfile = .generic

    private var connectionCompletion: ((CBPeripheral?, Error?) -> Void)?
    private var connectionTimeout: Task<Void, Never>?

    var connectionStatePublisher: AnyPublisher<ConnectionState, Never> {
        $connectionState.eraseToAnyPublisher()
    }

    var connectedPeripheralPublisher: AnyPublisher<CBPeripheral?, Never> {
        $connectedPeripheral.eraseToAnyPublisher()
    }

    // Full UUIDs to make CX handling explicit
    static let cxService = CBUUID(string: "0000FFF0-0000-1000-8000-00805F9B34FB")
    static let cxNotify = CBUUID(string: "0000FFF1-0000-1000-8000-00805F9B34FB")
    static let cxWrite  = CBUUID(string: "0000FFF2-0000-1000-8000-00805F9B34FB")

    static let defaultServices = [
        BLEConnection.cxService,
        CBUUID(string: "FFE0"),
        CBUUID(string: "18F0"),
        CBUUID(string: "FFF0"),
        CBUUID(string: "FFF1")
    ]

    init(centralManager: CBCentralManager, supportedServices: [CBUUID] = BLEConnection.defaultServices) {
        self.centralManager = centralManager
        self.supportedServices = supportedServices
        super.init()
        logger.debug("BLEConnection initialized with services: \(supportedServices.map(\.uuidString))")
    }

    func connect(to peripheral: CBPeripheral, timeout: TimeInterval = 10.0) async throws {
        guard let centralManager = centralManager else {
            throw BLEConnectionError.centralManagerNotAvailable
        }

        guard centralManager.state == .poweredOn else {
            throw BLEConnectionError.bluetoothNotPoweredOn
        }

        guard connectionState == .disconnected else {
            throw BLEConnectionError.alreadyConnected
        }

        logger.info("Attempting to connect to peripheral: \(peripheral.name ?? peripheral.identifier.uuidString) with timeout: \(timeout)s")

        return try await withTimeout(
            seconds: timeout,
            timeoutError: BLEConnectionError.connectionTimeout,
            onTimeout: { [weak self] in
                if let completion = self?.connectionCompletion {
                    completion(nil, BLEConnectionError.connectionTimeout)
                }
                self?.logger.error("Connection timed out after \(timeout) seconds")
                centralManager.cancelPeripheralConnection(peripheral)
                self?.resetConnectionState()
                self?.connectionCompletion = nil
            },
            operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    var hasResumed = false

                    self.connectionCompletion = { [weak self] connectedPeripheral, error in
                        guard !hasResumed else {
                            self?.logger.debug("Connection completion called but continuation already resumed")
                            return
                        }
                        hasResumed = true

                        if let connectedPeripheral = connectedPeripheral {
                            self?.logger.info("Successfully connected and configured: \(connectedPeripheral.name ?? connectedPeripheral.identifier.uuidString)")
                            continuation.resume(returning: ())
                        } else if let error = error {
                            self?.logger.error("Connection failed: \(error.localizedDescription)")
                            self?.resetConnectionState()
                            continuation.resume(throwing: error)
                        } else {
                            self?.logger.error("Connection failed with unknown error")
                            self?.resetConnectionState()
                            continuation.resume(throwing: BLEConnectionError.connectionFailed)
                        }
                        self?.connectionCompletion = nil
                    }

                    peripheral.delegate = self
                    centralManager.connect(peripheral, options: [
                        CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
                        CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                    ])

                    if centralManager.isScanning {
                        centralManager.stopScan()
                        self.logger.debug("Stopped scanning to focus on connection")
                    }
                }
            }
        )
    }

    func disconnect() {
        guard let peripheral = connectedPeripheral else {
            logger.debug("No peripheral connected to disconnect")
            return
        }

        logger.info("Disconnecting from peripheral: \(peripheral.name ?? peripheral.identifier.uuidString)")
        centralManager?.cancelPeripheralConnection(peripheral)
    }

    func isReady() -> Bool {
        let hasConnection = connectionState == .connectedToAdapter
        let hasReadChar = ecuReadCharacteristic != nil
        let hasWriteChar = ecuWriteCharacteristic != nil

        switch adapterProfile {
        case .obdLinkCX:
            logger.debug("isReady CX - Connection: \(hasConnection), Read: \(hasReadChar), Write: \(hasWriteChar)")
            return hasConnection && hasReadChar && hasWriteChar

        case .elmFFE0:
            let sameChar = ecuReadCharacteristic == ecuWriteCharacteristic
            logger.debug("isReady ELM FFE0 - Connection: \(hasConnection), Read: \(hasReadChar), Write: \(hasWriteChar), Same: \(sameChar)")
            return hasConnection && hasReadChar && (hasWriteChar || sameChar)

        case .vgate18F0, .generic:
            let sameChar = ecuReadCharacteristic == ecuWriteCharacteristic
            logger.debug("isReady Generic - Connection: \(hasConnection), Read: \(hasReadChar), Write: \(hasWriteChar), Same: \(sameChar)")
            return hasConnection && hasReadChar && (hasWriteChar || sameChar)
        }
    }

    func handleDidConnect(_ peripheral: CBPeripheral) {
        logger.info("Connected to peripheral: \(peripheral.name ?? "Unnamed")")
        connectedPeripheral = peripheral
        connectionState = .connectedToAdapter

        // Ask for all services first so we can detect the profile reliably
        peripheral.discoverServices(nil)

        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "lastConnectedPeripheral")
    }

    func handleDidDisconnect(_ peripheral: CBPeripheral, error: Error?) {
        if let error = error {
            logger.warning("Disconnected from peripheral with error: \(error.localizedDescription)")
        } else {
            logger.info("Disconnected from peripheral: \(peripheral.name ?? "Unnamed")")
        }

        resetConnectionState()
    }

    func handleDidFailToConnect(_: CBPeripheral, error: Error?) {
        let errorMessage = error?.localizedDescription ?? "Unknown error"
        logger.error("Failed to connect to peripheral: \(errorMessage)")

        if let completion = connectionCompletion {
            completion(nil, error ?? BLEConnectionError.connectionFailed)
        } else {
            logger.debug("Connection failure handled but completion was already cleared")
        }
    }

    func handleDidDiscoverServices(_ peripheral: CBPeripheral, error: Error?) {
        if let error = error {
            logger.error("Service discovery failed: \(error.localizedDescription)")
            connectionTimeout?.cancel()
            connectionCompletion?(nil, error)
            return
        }

        guard let services = peripheral.services, !services.isEmpty else {
            logger.error("No services found on peripheral")
            connectionTimeout?.cancel()
            connectionCompletion?(nil, BLEConnectionError.noServicesFound)
            return
        }

        logger.info("Discovered \(services.count) services")

        adapterProfile = determineProfile(from: services)
        logger.info("Detected adapter profile: \(adapterProfile.rawValue)")

        for service in services {
            logger.info("Discovered service: \(service.uuid.uuidString)")
            discoverCharacteristicsForService(service, on: peripheral)
        }
    }

    func handleDidDiscoverCharacteristics(_ peripheral: CBPeripheral, service: CBService, error: Error?) {
        if let error = error {
            logger.error("Characteristic discovery failed for \(service.uuid.uuidString): \(error.localizedDescription)")
            return
        }

        guard let characteristics = service.characteristics, !characteristics.isEmpty else {
            logger.warning("No characteristics found for service: \(service.uuid.uuidString)")
            return
        }

        for characteristic in characteristics {
            configureCharacteristic(characteristic, on: peripheral)
        }

        if isReady() {
            logger.info("Required characteristics discovered and configured for profile: \(adapterProfile.rawValue)")
            connectionTimeout?.cancel()
            connectionTimeout = nil
            connectionCompletion?(peripheral, nil)
        }
    }

    private func determineProfile(from services: [CBService]) -> BLEAdapterProfile {
        let uuids = Set(services.map { normalizedUUID($0.uuid) })

        if uuids.contains("FFF0") {
            return .obdLinkCX
        }
        if uuids.contains("FFE0") {
            return .elmFFE0
        }
        if uuids.contains("18F0") {
            return .vgate18F0
        }
        return .generic
    }

    private func discoverCharacteristicsForService(_ service: CBService, on peripheral: CBPeripheral) {
        let serviceUUID = normalizedUUID(service.uuid)
        let characteristicUUIDs: [CBUUID]

        switch serviceUUID {
        case "FFF0":
            characteristicUUIDs = [Self.cxNotify, Self.cxWrite]

        case "FFE0":
            characteristicUUIDs = [CBUUID(string: "FFE1")]

        case "18F0":
            characteristicUUIDs = [CBUUID(string: "2AF0"), CBUUID(string: "2AF1")]

        default:
            characteristicUUIDs = []
        }

        peripheral.discoverCharacteristics(characteristicUUIDs.isEmpty ? nil : characteristicUUIDs, for: service)
    }

    private func configureCharacteristic(_ characteristic: CBCharacteristic, on peripheral: CBPeripheral) {
        let uuid = normalizedUUID(characteristic.uuid)
        let properties = characteristic.properties

        logger.debug("Configuring characteristic \(uuid) with properties: \(String(describing: properties)) for profile \(adapterProfile.rawValue)")

        switch adapterProfile {
        case .obdLinkCX:
            configureForOBDLinkCX(characteristic, uuid: uuid, properties: properties, peripheral: peripheral)

        case .elmFFE0:
            configureForFFE0(characteristic, uuid: uuid, properties: properties, peripheral: peripheral)

        case .vgate18F0:
            configureFor18F0(characteristic, uuid: uuid, properties: properties, peripheral: peripheral)

        case .generic:
            configureGeneric(characteristic, uuid: uuid, properties: properties, peripheral: peripheral)
        }
    }

    private func configureForOBDLinkCX(
        _ characteristic: CBCharacteristic,
        uuid: String,
        properties: CBCharacteristicProperties,
        peripheral: CBPeripheral
    ) {
        switch uuid {
        case "FFF1":
            ecuReadCharacteristic = characteristic
            if properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
            logger.info("Configured FFF1 as notify/read characteristic")

        case "FFF2":
            ecuWriteCharacteristic = characteristic
            logger.info("Configured FFF2 as write characteristic")

        default:
            logger.debug("Ignoring non-CX characteristic \(uuid)")
        }
    }

    private func configureForFFE0(
        _ characteristic: CBCharacteristic,
        uuid: String,
        properties: CBCharacteristicProperties,
        peripheral: CBPeripheral
    ) {
        if uuid == "FFE1" {
            ecuReadCharacteristic = characteristic
            ecuWriteCharacteristic = characteristic

            if properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: characteristic)
            }

            logger.info("Configured FFE1 as both read and write characteristic")
            return
        }

        configureGeneric(characteristic, uuid: uuid, properties: properties, peripheral: peripheral)
    }

    private func configureFor18F0(
        _ characteristic: CBCharacteristic,
        uuid: String,
        properties: CBCharacteristicProperties,
        peripheral: CBPeripheral
    ) {
        switch uuid {
        case "2AF0":
            ecuReadCharacteristic = characteristic
            if properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
            logger.info("Configured 2AF0 as read characteristic")

        case "2AF1":
            ecuWriteCharacteristic = characteristic
            logger.info("Configured 2AF1 as write characteristic")

        default:
            configureGeneric(characteristic, uuid: uuid, properties: properties, peripheral: peripheral)
        }
    }

    private func configureGeneric(
        _ characteristic: CBCharacteristic,
        uuid: String,
        properties: CBCharacteristicProperties,
        peripheral: CBPeripheral
    ) {
        if properties.contains(.notify), ecuReadCharacteristic == nil {
            ecuReadCharacteristic = characteristic
            peripheral.setNotifyValue(true, for: characteristic)
            logger.info("Auto-assigned \(uuid) as notify/read characteristic")
        } else if properties.contains(.read), ecuReadCharacteristic == nil {
            ecuReadCharacteristic = characteristic
            logger.info("Auto-assigned \(uuid) as read characteristic")
        }

        if (properties.contains(.write) || properties.contains(.writeWithoutResponse)),
           ecuWriteCharacteristic == nil {
            ecuWriteCharacteristic = characteristic
            logger.info("Auto-assigned \(uuid) as write characteristic")
        }

        if ecuReadCharacteristic == nil,
           ecuWriteCharacteristic == nil,
           properties.contains(.read),
           properties.contains(.write) {
            ecuReadCharacteristic = characteristic
            ecuWriteCharacteristic = characteristic
            logger.info("Auto-assigned \(uuid) as both read and write characteristic")
        }
    }

    private func normalizedUUID(_ uuid: CBUUID) -> String {
        let s = uuid.uuidString.uppercased()
        if s.hasPrefix("0000"), s.hasSuffix("-0000-1000-8000-00805F9B34FB") {
            return String(s.dropFirst(4).prefix(4))
        }
        return s
    }

    private func resetConnectionState() {
        ecuReadCharacteristic = nil
        ecuWriteCharacteristic = nil
        connectedPeripheral = nil
        connectionState = .disconnected
        adapterProfile = .generic
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

extension BLEConnection: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        handleDidDiscoverServices(peripheral, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        handleDidDiscoverCharacteristics(peripheral, service: service, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let centralManager = centralManager, let delegate = centralManager.delegate as? CBPeripheralDelegate {
            delegate.peripheral?(peripheral, didUpdateValueFor: characteristic, error: error)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let centralManager = centralManager, let delegate = centralManager.delegate as? CBPeripheralDelegate {
            delegate.peripheral?(peripheral, didWriteValueFor: characteristic, error: error)
        }
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
