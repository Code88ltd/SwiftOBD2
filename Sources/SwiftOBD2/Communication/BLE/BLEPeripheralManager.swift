import Foundation
import OSLog
import CoreBluetooth
import Combine

protocol BLEPeripheralManagerDelegate: AnyObject {
    func peripheralManager(_ manager: BLEPeripheralManager, didSetupCharacteristics peripheral: CBPeripheral)
}

class BLEPeripheralManager: NSObject, ObservableObject {
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
        connectedPeripheral?.delegate = nil
        connectedPeripheral = peripheral
        connectedPeripheral?.delegate = self

        if let peripheral = peripheral {
            peripheral.discoverServices(BLEPeripheralScanner.supportedServices)
        }
    }

    func waitForCharacteristicsSetup(timeout: TimeInterval) async throws {
        try await withTimeout(seconds: timeout) { [self] in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.connectionCompletion = { peripheral, error in
                    if peripheral != nil {
                        continuation.resume()
                    } else if let error = error {
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
            logger.error("Error discovering services: \(error.localizedDescription)")
            connectionCompletion?(nil, error)
            return
        }

        for service in peripheral.services ?? [] {
            logger.info("Discovered service: \(service.uuid.uuidString)")
            characteristicHandler.discoverCharacteristics(for: service, on: peripheral)
        }
    }

    func didDiscoverCharacteristics(_ peripheral: CBPeripheral, service: CBService, error: Error?) {
        if let error = error {
            logger.error("Error discovering characteristics: \(error.localizedDescription)")
            connectionCompletion?(nil, error)
            return
        }

        guard let characteristics = service.characteristics else { return }

        characteristicHandler.setupCharacteristics(characteristics, on: peripheral)

        if characteristicHandler.isReady {
            connectionCompletion?(peripheral, nil)
            connectionCompletion = nil
            delegate?.peripheralManager(self, didSetupCharacteristics: peripheral)
        }
    }

    func didUpdateValue(_ peripheral: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            logger.error("Error reading characteristic value: \(error.localizedDescription)")
            return
        }

        guard let data = characteristic.value else { return }
        characteristicHandler.handleUpdatedValue(data, from: characteristic)
    }

    func didWriteValue(_ peripheral: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
        characteristicHandler.handleDidWriteValue(for: characteristic, error: error)
    }

    func didUpdateNotificationState(_ peripheral: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
        characteristicHandler.handleDidUpdateNotificationState(for: characteristic, error: error)

        if characteristicHandler.isReady, connectionCompletion != nil, let connectedPeripheral {
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
