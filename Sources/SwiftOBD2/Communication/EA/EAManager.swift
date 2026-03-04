import Combine
import CoreBluetooth // only because CommProtocol references CBPeripheral
import ExternalAccessory
import Foundation
import OSLog

final class EAManager: NSObject, CommProtocol, StreamDelegate {

    // MARK: - CommProtocol
    @Published var connectionState: ConnectionState = .disconnected
    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }
    public weak var obdDelegate: OBDServiceDelegate?

    // MARK: - Config
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.swiftobd2.app",
                                category: "EAManager")
    private let protocolString = "com.obdlink"

    // MARK: - EA session
    private var accessory: EAAccessory?
    private var session: EASession?
    private var input: InputStream?
    private var output: OutputStream?

    // MARK: - Rx buffer / completion
    private var buffer = Data()
    private var messageCompletion: (([String]?, Error?) -> Void)?

    // ✅ Match BLE behavior: prevent concurrent commands
    private let commandLock = AsyncLock()

    // Use a queue for stream processing
    private let ioQueue = DispatchQueue(label: "com.swiftobd2.ea.io", qos: .userInitiated)

    // MARK: - Lifecycle
    override init() {
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
        disconnectPeripheral()
    }

    // MARK: - CommProtocol

    func connectAsync(timeout: TimeInterval, peripheral _: CBPeripheral? = nil) async throws {
        let old = connectionState
        connectionState = .connecting
        if old != connectionState { DispatchQueue.main.async { self.obdDelegate?.connectionStateChanged(state: .connecting) } }

        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if try openSessionIfAvailable() {
                let old2 = connectionState
                connectionState = .connectedToAdapter
                if old2 != connectionState {
                    DispatchQueue.main.async { self.obdDelegate?.connectionStateChanged(state: .connectedToAdapter) }
                }
                return
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        connectionState = .error
        DispatchQueue.main.async { self.obdDelegate?.connectionStateChanged(state: .error) }
        throw BLEManagerError.peripheralNotFound
    }

    func disconnectPeripheral() {
        ioQueue.sync {
            self.buffer.removeAll()

            let completion = self.messageCompletion
            self.messageCompletion = nil
            completion?(nil, BLEManagerError.peripheralNotConnected)

            self.input?.close()
            self.output?.close()
            self.input?.delegate = nil
            self.output?.delegate = nil
            self.input?.remove(from: .current, forMode: .default)
            self.output?.remove(from: .current, forMode: .default)
            self.input = nil
            self.output = nil
            self.session = nil
            self.accessory = nil
        }

        let old = connectionState
        connectionState = .disconnected
        if old != connectionState {
            DispatchQueue.main.async { self.obdDelegate?.connectionStateChanged(state: .disconnected) }
        }
    }

    func scanForPeripherals() async throws {
        // ExternalAccessory cannot scan. No-op to match your protocol.
    }

    func sendCommand(_ command: String, retries: Int) async throws -> [String] {
        // Same guard spirit as BLEManager
        guard connectionState == .connectedToAdapter, output != nil else {
            throw BLEManagerError.missingPeripheralOrCharacteristic
        }

        // Serialize just like BLEMessageProcessor
        await commandLock.lock()
        defer { Task { await commandLock.unlock() } }

        var lastError: Error?

        for attempt in 1...max(1, retries) {
            do {
                try writeCommand(command)
                let response = try await waitForResponse(timeout: BLEConstants.defaultTimeout)
                logger.debug("EA response: \(response.joined(separator: " | "), privacy: .public)")
                return response
            } catch {
                lastError = error
                if attempt < retries {
                    try await Task.sleep(nanoseconds: UInt64(BLEConstants.retryDelay * 1_000_000_000))
                    continue
                }
            }
        }

        throw lastError ?? BLEManagerError.unknownError
    }

    // MARK: - Internals

    private func openSessionIfAvailable() throws -> Bool {
        let accessories = EAAccessoryManager.shared().connectedAccessories
        guard let acc = accessories.first(where: { $0.protocolStrings.contains(protocolString) }) else {
            return false
        }

        accessory = acc
        guard let sess = EASession(accessory: acc, forProtocol: protocolString) else {
            throw BLEManagerError.unknownError
        }

        session = sess
        input = sess.inputStream
        output = sess.outputStream

        input?.delegate = self
        output?.delegate = self

        // IMPORTANT: schedule streams on a run loop
        // We schedule on the main run loop because your app definitely has one.
        input?.schedule(in: .main, forMode: .default)
        output?.schedule(in: .main, forMode: .default)

        input?.open()
        output?.open()

        logger.info("EA session opened: \(acc.name, privacy: .public)")
        return true
    }

    private func writeCommand(_ command: String) throws {
        guard let output else { throw BLEManagerError.missingPeripheralOrCharacteristic }
        guard let data = "\(command)\r".data(using: .ascii) else { throw BLEManagerError.stringConversionFailed }

        logger.debug("Sending EA command: \(command, privacy: .public)")

        try data.withUnsafeBytes { ptr in
            guard let base = ptr.bindMemory(to: UInt8.self).baseAddress else {
                throw BLEManagerError.incorrectDataConversion
            }
            var remaining = ptr.count
            var offset = 0
            while remaining > 0 {
                let written = output.write(base.advanced(by: offset), maxLength: remaining)
                if written <= 0 {
                    throw BLEManagerError.sendMessageTimeout
                }
                remaining -= written
                offset += written
            }
        }
    }

    /// Mirrors BLEMessageProcessor.waitForResponse(timeout:)
    private func waitForResponse(timeout: TimeInterval) async throws -> [String] {
        try await withTimeout(seconds: timeout, timeoutError: BLEManagerError.timeout) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in

                // Defensive: should never happen due to commandLock
                if self.messageCompletion != nil {
                    continuation.resume(throwing: BLEMessageProcessorError.concurrentCommand)
                    return
                }

                self.messageCompletion = { lines, error in
                    self.messageCompletion = nil
                    if let lines { continuation.resume(returning: lines) }
                    else if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(throwing: BLEManagerError.timeout) }
                }
            }
        }
    }

    /// Mirrors BLEMessageProcessor.parseResponse(from:)
    private func parseResponse(from string: String) -> [String] {
        let cleaned = string.replacingOccurrences(of: ">", with: "")

        return cleaned
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func handleParsedResponse(_ lines: [String]) {
        let completion = messageCompletion
        messageCompletion = nil

        guard let completion else {
            logger.warning("Received EA response with no pending completion")
            return
        }

        if let first = lines.first, first.uppercased().contains("NO DATA") {
            completion(nil, BLEManagerError.noData)
        } else if lines.isEmpty {
            completion(nil, BLEManagerError.noData)
        } else {
            completion(lines, nil)
        }
    }

    // MARK: - StreamDelegate

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable:
            guard aStream === input else { return }
            readAvailable()
        case .errorOccurred, .endEncountered:
            disconnectPeripheral()
        default:
            break
        }
    }

    private func readAvailable() {
        guard let input else { return }

        var tmp = [UInt8](repeating: 0, count: 4096)

        while input.hasBytesAvailable {
            let n = input.read(&tmp, maxLength: tmp.count)
            if n > 0 {
                ioQueue.async {
                    self.buffer.append(contentsOf: tmp[0..<n])

                    guard let string = String(data: self.buffer, encoding: .utf8) else {
                        if self.buffer.count > BLEConstants.maxBufferSize {
                            self.buffer.removeAll()
                        }
                        return
                    }

                    if string.contains(">") {
                        let lines = self.parseResponse(from: string)
                        self.handleParsedResponse(lines)
                        self.buffer.removeAll()
                    }
                }
            } else {
                break
            }
        }
    }

    // MARK: - Accessory notifications

    @objc private func accessoryDidConnect(_ note: Notification) {
        guard let acc = note.userInfo?[EAAccessoryKey] as? EAAccessory else { return }
        guard acc.protocolStrings.contains(protocolString) else { return }
        logger.info("EA accessory connected: \(acc.name, privacy: .public)")
    }

    @objc private func accessoryDidDisconnect(_ note: Notification) {
        guard let acc = note.userInfo?[EAAccessoryKey] as? EAAccessory else { return }
        if acc.connectionID == accessory?.connectionID {
            logger.info("EA accessory disconnected: \(acc.name, privacy: .public)")
            disconnectPeripheral()
        }
    }
}
