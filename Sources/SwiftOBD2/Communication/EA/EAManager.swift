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

    // MARK: - SwiftOBD2 log bridge (to app via NotificationCenter)
    private let logCategory = "EA"
    private var lastCommand: String?
    private var openAttempts: Int = 0

    private func post(_ level: SwiftOBD2LogLevel, _ message: String, meta: [String: String]? = nil) {
        SwiftOBD2Logger.post(level, category: logCategory, message, meta: meta)
    }

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

        post(.info, "EAManager init", meta: ["protocol": protocolString])
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        EAAccessoryManager.shared().unregisterForLocalNotifications()
        post(.info, "EAManager deinit")
        disconnectPeripheral()
    }

    // MARK: - CommProtocol

    func connectAsync(timeout: TimeInterval, peripheral _: CBPeripheral? = nil) async throws {
        post(.info, "connectAsync start", meta: [
            "timeout": "\(timeout)",
            "protocol": protocolString
        ])

        let old = connectionState
        connectionState = .connecting
        if old != connectionState {
            DispatchQueue.main.async { self.obdDelegate?.connectionStateChanged(state: .connecting) }
        }

        let deadline = Date().addingTimeInterval(timeout)
        openAttempts = 0

        while Date() < deadline {
            do {
                openAttempts += 1
                if try openSessionIfAvailable() {
                    let old2 = connectionState
                    connectionState = .connectedToAdapter
                    if old2 != connectionState {
                        DispatchQueue.main.async { self.obdDelegate?.connectionStateChanged(state: .connectedToAdapter) }
                    }
                    post(.info, "connectAsync success", meta: [
                        "attempts": "\(openAttempts)",
                        "accessory": accessory?.name ?? "nil"
                    ])
                    return
                } else {
                    let remaining = max(0, deadline.timeIntervalSinceNow)
                    post(.debug, "connectAsync waiting for accessory", meta: [
                        "attempt": "\(openAttempts)",
                        "remaining_s": String(format: "%.2f", remaining)
                    ])
                }
            } catch {
                post(.error, "openSessionIfAvailable threw", meta: [
                    "attempt": "\(openAttempts)",
                    "error": error.localizedDescription
                ])
                throw error
            }

            try await Task.sleep(nanoseconds: 250_000_000)
        }

        connectionState = .error
        DispatchQueue.main.async { self.obdDelegate?.connectionStateChanged(state: .error) }

        post(.error, "connectAsync timeout", meta: [
            "timeout": "\(timeout)",
            "attempts": "\(openAttempts)"
        ])

        throw BLEManagerError.peripheralNotFound
    }

    func disconnectPeripheral() {
        post(.info, "disconnectPeripheral", meta: [
            "state": "\(connectionState)",
            "accessory": accessory?.name ?? "nil",
            "lastCommand": lastCommand ?? "nil"
        ])

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
        post(.debug, "scanForPeripherals no-op (EA)")
        // ExternalAccessory cannot scan. No-op to match your protocol.
    }

    func sendCommand(_ command: String, retries: Int) async throws -> [String] {
        // Same guard spirit as BLEManager
        guard connectionState == .connectedToAdapter, output != nil else {
            post(.warning, "sendCommand blocked (not ready)", meta: [
                "state": "\(connectionState)",
                "hasOutput": "\(output != nil)",
                "command": command
            ])
            throw BLEManagerError.missingPeripheralOrCharacteristic
        }

        // Serialize just like BLEMessageProcessor
        await commandLock.lock()
        defer { Task { await commandLock.unlock() } }

        lastCommand = command
        post(.debug, "sendCommand begin", meta: [
            "command": command,
            "retries": "\(retries)"
        ])

        var lastError: Error?

        for attempt in 1...max(1, retries) {
            do {
                try writeCommand(command)
                let response = try await waitForResponse(timeout: BLEConstants.defaultTimeout)
                let joined = response.joined(separator: " | ")

                logger.debug("EA response: \(joined, privacy: .public)")
                post(.debug, "sendCommand response", meta: [
                    "command": command,
                    "attempt": "\(attempt)",
                    "lines": "\(response.count)",
                    "rx": joined
                ])

                return response
            } catch {
                lastError = error
                post(.warning, "sendCommand attempt failed", meta: [
                    "command": command,
                    "attempt": "\(attempt)",
                    "error": error.localizedDescription
                ])

                if attempt < retries {
                    try await Task.sleep(nanoseconds: UInt64(BLEConstants.retryDelay * 1_000_000_000))
                    continue
                }
            }
        }

        post(.error, "sendCommand failed", meta: [
            "command": command,
            "error": (lastError?.localizedDescription ?? "unknown")
        ])

        throw lastError ?? BLEManagerError.unknownError
    }

    // MARK: - Internals

    private func openSessionIfAvailable() throws -> Bool {
        let accessories = EAAccessoryManager.shared().connectedAccessories

        post(.debug, "openSessionIfAvailable", meta: [
            "connectedAccessories": "\(accessories.count)",
            "protocolWanted": protocolString
        ])

        // Log what iOS can currently see (this is the key diagnostic)
        if !accessories.isEmpty {
            for acc in accessories {
                post(.debug, "EA accessory seen", meta: [
                    "name": acc.name,
                    "manufacturer": acc.manufacturer,
                    "modelNumber": acc.modelNumber,
                    "serialNumber": acc.serialNumber,
                    "connectionID": "\(acc.connectionID)",
                    "protocols": acc.protocolStrings.joined(separator: ",")
                ])
            }
        }

        guard let acc = accessories.first(where: { $0.protocolStrings.contains(protocolString) }) else {
            post(.debug, "no accessory matched protocol", meta: [
                "protocolWanted": protocolString
            ])
            return false
        }

        accessory = acc

        guard let sess = EASession(accessory: acc, forProtocol: protocolString) else {
            post(.error, "EASession returned nil", meta: [
                "accessory": acc.name,
                "protocol": protocolString
            ])
            throw BLEManagerError.unknownError
        }

        session = sess
        input = sess.inputStream
        output = sess.outputStream

        input?.delegate = self
        output?.delegate = self

        // IMPORTANT: schedule streams on a run loop
        input?.schedule(in: .main, forMode: .default)
        output?.schedule(in: .main, forMode: .default)

        input?.open()
        output?.open()

        post(.info, "EA session opened", meta: [
            "accessory": acc.name,
            "protocol": protocolString,
            "inputStatus": "\(input?.streamStatus.rawValue ?? -1)",
            "outputStatus": "\(output?.streamStatus.rawValue ?? -1)"
        ])

        logger.info("EA session opened: \(acc.name, privacy: .public)")
        return true
    }

  private func writeCommand(_ command: String) throws {
    guard let output else { throw BLEManagerError.missingPeripheralOrCharacteristic }
    guard let data = "\(command)\r".data(using: .ascii) else { throw BLEManagerError.stringConversionFailed }

    SwiftOBD2Logger.post(.debug, category: "EA", "TX \(command)")

    try data.withUnsafeBytes { ptr in
        guard let base = ptr.bindMemory(to: UInt8.self).baseAddress else {
            throw BLEManagerError.incorrectDataConversion
        }

        var remaining: Int = ptr.count
        var offset: Int = 0

        while remaining > 0 {
            let written: Int = output.write(base.advanced(by: offset), maxLength: remaining)

            if written <= 0 {
                SwiftOBD2Logger.post(.error, category: "EA", "Write failed (written=\(written))", meta: [
                    "command": command
                ])
                throw BLEManagerError.sendMessageTimeout
            }

            remaining -= written
            offset += written
        }
    }
}

    /// Mirrors BLEMessageProcessor.waitForResponse(timeout:)
    private func waitForResponse(timeout: TimeInterval) async throws -> [String] {
        post(.debug, "waitForResponse start", meta: [
            "timeout": "\(timeout)",
            "lastCommand": lastCommand ?? "nil"
        ])

        do {
            let lines = try await withTimeout(seconds: timeout, timeoutError: BLEManagerError.timeout) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in

                    // Defensive: should never happen due to commandLock
                    if self.messageCompletion != nil {
                        self.post(.error, "concurrentCommand detected", meta: [
                            "lastCommand": self.lastCommand ?? "nil"
                        ])
                        continuation.resume(throwing: BLEMessageProcessorError.concurrentCommand)
                        return
                    }

                    self.messageCompletion = { lines, error in
                        self.messageCompletion = nil
                        if let lines {
                            continuation.resume(returning: lines)
                        } else if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(throwing: BLEManagerError.timeout)
                        }
                    }
                }
            }

            post(.debug, "waitForResponse done", meta: [
                "lines": "\(lines.count)"
            ])
            return lines
        } catch {
            post(.warning, "waitForResponse error", meta: [
                "error": error.localizedDescription,
                "lastCommand": lastCommand ?? "nil"
            ])
            throw error
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
            post(.warning, "received response with no pending completion", meta: [
                "lines": "\(lines.count)"
            ])
            logger.warning("Received EA response with no pending completion")
            return
        }

        if let first = lines.first, first.uppercased().contains("NO DATA") {
            post(.warning, "NO DATA", meta: [
                "lastCommand": lastCommand ?? "nil"
            ])
            completion(nil, BLEManagerError.noData)
        } else if lines.isEmpty {
            post(.warning, "empty response lines", meta: [
                "lastCommand": lastCommand ?? "nil"
            ])
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
        case .errorOccurred:
            post(.error, "stream errorOccurred", meta: [
                "stream": (aStream === input) ? "input" : "output",
                "error": aStream.streamError?.localizedDescription ?? "nil"
            ])
            disconnectPeripheral()
        case .endEncountered:
            post(.warning, "stream endEncountered", meta: [
                "stream": (aStream === input) ? "input" : "output"
            ])
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

                    // Light-weight byte logging (don’t spam full payloads)
                    self.post(.debug, "read bytes", meta: [
                        "n": "\(n)",
                        "bufferBytes": "\(self.buffer.count)"
                    ])

                    guard let string = String(data: self.buffer, encoding: .utf8) else {
                        self.post(.warning, "buffer not utf8 yet", meta: [
                            "bufferBytes": "\(self.buffer.count)"
                        ])
                        if self.buffer.count > BLEConstants.maxBufferSize {
                            self.post(.warning, "buffer exceeded max, clearing", meta: [
                                "max": "\(BLEConstants.maxBufferSize)"
                            ])
                            self.buffer.removeAll()
                        }
                        return
                    }

                    if string.contains(">") {
                        let lines = self.parseResponse(from: string)
                        self.post(.debug, "prompt detected", meta: [
                            "lines": "\(lines.count)",
                            "rx": lines.joined(separator: " | ")
                        ])
                        self.handleParsedResponse(lines)
                        self.buffer.removeAll()
                    }
                }
            } else if n < 0 {
                post(.error, "input.read returned < 0", meta: [
                    "error": input.streamError?.localizedDescription ?? "nil"
                ])
                break
            } else {
                break
            }
        }
    }

    // MARK: - Accessory notifications

    @objc private func accessoryDidConnect(_ note: Notification) {
        guard let acc = note.userInfo?[EAAccessoryKey] as? EAAccessory else { return }
        guard acc.protocolStrings.contains(protocolString) else { return }

        post(.info, "EA accessory connected notification", meta: [
            "name": acc.name,
            "connectionID": "\(acc.connectionID)",
            "protocols": acc.protocolStrings.joined(separator: ",")
        ])

        logger.info("EA accessory connected: \(acc.name, privacy: .public)")
    }

    @objc private func accessoryDidDisconnect(_ note: Notification) {
        guard let acc = note.userInfo?[EAAccessoryKey] as? EAAccessory else { return }
        if acc.connectionID == accessory?.connectionID {
            post(.warning, "EA accessory disconnected notification", meta: [
                "name": acc.name,
                "connectionID": "\(acc.connectionID)"
            ])

            logger.info("EA accessory disconnected: \(acc.name, privacy: .public)")
            disconnectPeripheral()
        }
    }
}
