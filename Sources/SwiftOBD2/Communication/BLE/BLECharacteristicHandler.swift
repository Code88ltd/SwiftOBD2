import Foundation
import OSLog
import CoreBluetooth

final class BLECharacteristicHandler: NSObject {
    private var ecuReadCharacteristic: CBCharacteristic?
    private var ecuWriteCharacteristic: CBCharacteristic?

    private let messageProcessor: BLEMessageProcessor
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.example.app",
        category: "BLECharacteristicHandler"
    )

    private var notifyReady = false
    private var writeCompletion: ((Error?) -> Void)?

    var isReady: Bool {
        ecuReadCharacteristic != nil && ecuWriteCharacteristic != nil && notifyReady
    }

    init(messageProcessor: BLEMessageProcessor) {
        self.messageProcessor = messageProcessor
        super.init()
    }

    func setupCharacteristics(_ characteristics: [CBCharacteristic], on peripheral: CBPeripheral) {
        for characteristic in characteristics {
            let uuid = normalizedUUID(characteristic.uuid)
            let props = characteristic.properties

            logger.info("Characteristic \(uuid) props: \(String(describing: props))")

            switch uuid {
            case "FFE1":
                // Generic ELM BLE adapters often use a single characteristic for read/write
                if props.contains(.notify) {
                    ecuReadCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                } else if props.contains(.read) {
                    ecuReadCharacteristic = characteristic
                    // No notify on this char, so treat read path as ready
                    notifyReady = true
                }

                if props.contains(.write) || props.contains(.writeWithoutResponse) {
                    ecuWriteCharacteristic = characteristic
                }

            case "FFF1":
                // OBDLink CX notify/read
                if props.contains(.notify) {
                    ecuReadCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                } else if props.contains(.read) {
                    ecuReadCharacteristic = characteristic
                    notifyReady = true
                }

            case "FFF2":
                // OBDLink CX write
                if props.contains(.write) || props.contains(.writeWithoutResponse) {
                    ecuWriteCharacteristic = characteristic
                }

            case "2AF0":
                if props.contains(.notify) {
                    ecuReadCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                } else if props.contains(.read) {
                    ecuReadCharacteristic = characteristic
                    notifyReady = true
                }

            case "2AF1":
                if props.contains(.write) || props.contains(.writeWithoutResponse) {
                    ecuWriteCharacteristic = characteristic
                }

            default:
                logger.debug("Unknown characteristic: \(characteristic.uuid.uuidString)")
            }
        }

        logger.info("Characteristics setup - Read: \(self.ecuReadCharacteristic != nil), Write: \(self.ecuWriteCharacteristic != nil), NotifyReady: \(self.notifyReady)")
    }

    func discoverCharacteristics(for service: CBService, on peripheral: CBPeripheral) {
        switch normalizedUUID(service.uuid) {
        case "FFE0":
            peripheral.discoverCharacteristics([CBUUID(string: "FFE1")], for: service)

        case "FFF0":
            peripheral.discoverCharacteristics([
                CBUUID(string: "0000FFF1-0000-1000-8000-00805F9B34FB"),
                CBUUID(string: "0000FFF2-0000-1000-8000-00805F9B34FB")
            ], for: service)

        case "18F0":
            peripheral.discoverCharacteristics([CBUUID(string: "2AF0"), CBUUID(string: "2AF1")], for: service)

        default:
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func writeCommand(_ command: String, to peripheral: CBPeripheral) async throws {
        guard let characteristic = ecuWriteCharacteristic,
              let data = "\(command)\r".data(using: .ascii) else {
            throw BLEManagerError.missingPeripheralOrCharacteristic
        }

        // Prefer withResponse whenever available.
        // OBDLink recommends waiting for each write response before sending another write.
        let writeType: CBCharacteristicWriteType =
            characteristic.properties.contains(.write) ? .withResponse : .withoutResponse

        if writeType == .withoutResponse {
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
            logger.info("Sent command without response: \(command)")
            return
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.writeCompletion = { error in
                self.writeCompletion = nil
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }

            peripheral.writeValue(data, for: characteristic, type: .withResponse)
            logger.info("Sent command with response: \(command)")
        }
    }

    func handleUpdatedValue(_ data: Data, from characteristic: CBCharacteristic) {
        guard characteristic == ecuReadCharacteristic else {
            if let responseString = String(data: data, encoding: .utf8) {
                logger.info("Ignoring data from non-read characteristic: \(characteristic.uuid.uuidString) response: \(responseString)")
            }
            return
        }

        messageProcessor.processReceivedData(data)
    }

    func handleDidWriteValue(for characteristic: CBCharacteristic, error: Error?) {
        guard characteristic == ecuWriteCharacteristic else { return }
        writeCompletion?(error)
    }

    func handleDidUpdateNotificationState(for characteristic: CBCharacteristic, error: Error?) {
        if let error {
            logger.error("Notify state update failed for \(characteristic.uuid.uuidString): \(error.localizedDescription)")
            return
        }

        if characteristic == ecuReadCharacteristic {
            notifyReady = characteristic.isNotifying || !characteristic.properties.contains(.notify)
            logger.info("Notify ready for \(characteristic.uuid.uuidString): \(self.notifyReady)")
        }
    }

    func reset() {
        ecuReadCharacteristic = nil
        ecuWriteCharacteristic = nil
        notifyReady = false
        writeCompletion = nil
    }

    private func normalizedUUID(_ uuid: CBUUID) -> String {
        let s = uuid.uuidString.uppercased()
        if s.hasPrefix("0000"), s.hasSuffix("-0000-1000-8000-00805F9B34FB") {
            return String(s.dropFirst(4).prefix(4))
        }
        return s
    }
}
