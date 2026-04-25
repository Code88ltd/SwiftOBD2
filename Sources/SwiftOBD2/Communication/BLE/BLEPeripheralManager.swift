import Foundation
import OSLog
import CoreBluetooth
import Combine

protocol BLEPeripheralManagerDelegate: AnyObject {
    func peripheralManager(_ manager: BLEPeripheralManager, didSetupCharacteristics peripheral: CBPeripheral)
}

final class BLEPeripheralManager: NSObject, ObservableObject {
    @Published var connectedPeripheral: CBPeripheral?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.example.app",
        category: "BLEPeripheralManager"
    )

    private let characteristicHandler: BLECharacteristicHandler

    weak var delegate: BLEPeripheralManagerDelegate?
    private var connectionCompletion: ((CBPeripheral?, Error?) -> Void)?

    init(characteristicHandler: BLECharacteristicHandler) {
        self.characteristicHandler = characteristicHandler
        super.init()
    }

    func setPeripheral(_ peripheral: CBPeripheral?) {
        // If same peripheral, do nothing
        if connectedPeripheral?.identifier == peripheral?.identifier {
            logger.debug("Same peripheral already assigned")
            return
        }

        // Remove old delegate
        connectedPeripheral?.delegate = nil

        connectedPeripheral = peripheral
        connectedPeripheral?.delegate = self

        guard let peripheral else {
            logger.debug("Peripheral cleared")
            return
        }

        logger.info("Peripheral assigned: \(peripheral.name ?? peripheral.identifier.uuidString)")
        peripheral.discoverServices(BLEPeripheralScanner.supportedServices)
    }

    func waitForCharacteristicsSetup(timeout: TimeInterval) async throws {
        try await withTimeout(seconds: timeout) { [self] in
            try await withCheckedThrowingContinuation { continuation in
                self.connectionCompletion = { peripheral, error in
                    if peripheral != nil {
                        continuation.resume()
                    } else if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(throwing: BLEManagerError.unknownError)
                    }
                }
            }
        }
    }

    func didDiscoverServices(_ peripheral: CBPeripheral, error: Error?) {
        if let error {
            logger.error("Service discovery failed: \(error.localizedDescription)")
            connectionCompletion?(nil, error)
            connectionCompletion = nil
            return
        }

        let services = peripheral.services ?? []

        if services.isEmpty {
            logger.error("No services discovered")
            connectionCompletion?(nil, BLEManagerError.unknownError)
            connectionCompletion = nil
            return
        }

        for service in services {
            logger.info("Discovered service: \(service.uuid.uuidString)")
            characteristicHandler.discoverCharacteristics(for: service, on: peripheral)
        }
    }

    func didDiscoverCharacteristics(_ peripheral: CBPeripheral, service: CBService, error: Error?) {
        if let error {
            logger.error("Characteristic discovery failed: \(error.localizedDescription)")
            connectionCompletion?(nil, error)
            connectionCompletion = nil
            return
        }

        guard let characteristics = service.characteristics else { return }

        characteristicHandler.setupCharacteristics(characteristics, on: peripheral)

        if characteristicHandler.isReady {
            logger.info("Characteristics ready")
            connectionCompletion?(peripheral, nil)
            connectionCompletion = nil
            delegate?.peripheralManager(self, didSetupCharacteristics: peripheral)
        }
    }

    func didUpdateValue(_ peripheral: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
        if let error {
            logger.error("Characteristic update error: \(error.localizedDescription)")
            return
        }

        guard let data = characteristic.value else { return }

        logger.debug("RX \(characteristic.uuid.uuidString) bytes: \(data.count)")

        characteristicHandler.handleUpdatedValue(data, from: characteristic)
    }

    func didWriteValue(_ peripheral: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
        if let error {
            logger.error("Write error: \(error.localizedDescription)")
        }

        characteristicHandler.handleDidWriteValue(for: characteristic, error: error)
    }

    func didUpdateNotificationState(_ peripheral: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
        if let error {
            logger.error("Notify state error: \(error.localizedDescription)")
        }

        characteristicHandler.handleDidUpdateNotificationState(for: characteristic, error: error)

        if characteristicHandler.isReady,
           connectionCompletion != nil,
           let connectedPeripheral {
            logger.info("Notifications ready")
            connectionCompletion?(connectedPeripheral, nil)
            connectionCompletion = nil
            delegate?.peripheralManager(self, didSetupCharacteristics: connectedPeripheral)
        }
    }
}

extension BLEPeripheralManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        didDiscoverServices(peripheral, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        didDiscoverCharacteristics(peripheral, service: service, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        didUpdateValue(peripheral, characteristic: characteristic, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        didWriteValue(peripheral, characteristic: characteristic, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        didUpdateNotificationState(peripheral, characteristic: characteristic, error: error)
    }
}
