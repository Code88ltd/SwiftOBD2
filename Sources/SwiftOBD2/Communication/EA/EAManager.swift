//
//  EAManager.swift
//  SwiftOBD2 (or your app target if you’ve forked it)
//
//  Copy/paste replacement
//
//  Fixes:
//  ✅ write() == 0 on EA streams is NOT fatal (wait + retry)
//  ✅ Waits for output.hasSpaceAvailable before writing
//  ✅ Removes streams from the same RunLoop/mode they were scheduled on
//  ✅ Schedules streams on .common (more robust)
//
//  Keeps your:
//  ✅ SwiftOBD2Logger.post(...) bridge
//  ✅ attemptId correlation
//  ✅ rich diagnostics
//

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
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.swiftobd2.app",
        category: "EAManager"
    )
    private let protocolString = "com.obdlink"

    // MARK: - SwiftOBD2 log bridge (to app via NotificationCenter)
    private let logCategory = "EA"

    private var attemptId: String = ""
    private var selectedAdapterLabel: String = "OBDLink (EA)"
    private var lastCommand: String?
    private var openAttempts: Int = 0

    private func post(_ level: SwiftOBD2LogLevel, _ message: String, meta: [String: String]? = nil) {
        var m = meta ?? [:]
        if !attemptId.isEmpty { m["attemptId"] = attemptId }
        m["adapter"] = selectedAdapterLabel
        m["transport"] = "ea"
        m["protocol"] = protocolString
        SwiftOBD2Logger.post(level, category: logCategory, message, meta: m)
    }

    // MARK: - EA session
    private var accessory: EAAccessory?
    private var session: EASession?
    private var input: InputStream?
    private var output: OutputStream?

    // MARK: - Rx buffer / completion
    private var buffer = Data()
    private var messageCompletion: (([String]?, Error?) -> Void)?

    // ✅ Prevent concurrent commands
    private let commandLock = AsyncLock()

    // Use a queue for buffer processing
    private let ioQueue = DispatchQueue(label: "com.swiftobd2.ea.io", qos: .userInitiated)

    // MARK: - Lifecycle
    override init() {
        super.init()

        EAAccessoryManager.shared().registerForLocalNotifications()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accessoryDidConnect(_:)),
            name: .EAAccessoryDidConnect,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accessoryDidDisconnect(_:)),
            name: .EAAccessoryDidDisconnect,
            object: nil
        )

        post(.info, "EAManager init")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        EAAccessoryManager.shared().unregisterForLocalNotifications()
        post(.info, "EAManager deinit")
        disconnectPeripheral()
    }

    // MARK: - CommProtocol

    func connectAsync(timeout: TimeInterval, peripheral _: CBPeripheral? = nil) async throws {
        attemptId = UUID().uuidString
        openAttempts = 0

        post(.info, "connectAsync start", meta: [
            "timeout_s": String(format: "%.2f", timeout)
        ])

        let old = connectionState
        connectionState = .connecting
        if old != connectionState {
            DispatchQueue.main.async { self.obdDelegate?.connectionStateChanged(state: .connecting) }
        }

        let deadline = Date().addingTimeInterval(timeout)

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
            "timeout_s": String(format: "%.2f", timeout),
            "attempts": "\(openAttempts)"
        ])

        throw BLEManagerError.peripheralNotFound
    }

  func disconnectPeripheral() {

    post(.info, "disconnectPeripheral", meta: [
        "state": "\(connectionState)",
        "accessory": accessory?.name ?? "nil"
    ])

    func teardown() {

        buffer.removeAll()

        let completion = messageCompletion
        messageCompletion = nil
        completion?(nil, BLEManagerError.peripheralNotConnected)

        input?.close()
        output?.close()

        input?.delegate = nil
        output?.delegate = nil

        input?.remove(from: .main, forMode: .common)
        output?.remove(from: .main, forMode: .common)

        input = nil
        output = nil
        session = nil
        accessory = nil
    }

    // ✅ NEVER block the main thread
    if Thread.isMainThread {
        teardown()
    } else {
        DispatchQueue.main.async {
            teardown()
        }
    }

    let old = connectionState
    connectionState = .disconnected

    if old != connectionState {
        DispatchQueue.main.async {
            self.obdDelegate?.connectionStateChanged(state: .disconnected)
        }
    }
}

    func scanForPeripherals() async throws {
        post(.debug, "scanForPeripherals no-op (ExternalAccessory)")
        // ExternalAccessory cannot scan. No-op.
    }

    func sendCommand(_ command: String, retries: Int) async throws -> [String] {
        guard connectionState == .connectedToAdapter, output != nil else {
            post(.warning, "sendCommand blocked (not ready)", meta: [
                "state": "\(connectionState)",
                "hasOutput": "\(output != nil)",
                "command": command
            ])
            throw BLEManagerError.missingPeripheralOrCharacteristic
        }

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
                }
            }
        }

        post(.error, "sendCommand failed", meta: [
            "command": command,
            "error": lastError?.localizedDescription ?? "unknown"
        ])

        throw lastError ?? BLEManagerError.unknownError
    }

    // MARK: - Internals

    private func openSessionIfAvailable() throws -> Bool {
        let accessories = EAAccessoryManager.shared().connectedAccessories

        post(.debug, "openSessionIfAvailable", meta: [
            "connectedAccessories": "\(accessories.count)"
        ])

        // Log everything iOS sees
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
        } else {
            post(.debug, "EAAccessoryManager connectedAccessories is empty")
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

        // ✅ More robust: .common mode
        input?.schedule(in: .main, forMode: .common)
        output?.schedule(in: .main, forMode: .common)

        input?.open()
        output?.open()

        let inputStatus = input.map { String($0.streamStatus.rawValue) } ?? "nil"
        let outputStatus = output.map { String($0.streamStatus.rawValue) } ?? "nil"

        post(.info, "EA session opened", meta: [
            "accessory": acc.name,
            "inputStatus": inputStatus,
            "outputStatus": outputStatus
        ])

        logger.info("EA session opened: \(acc.name, privacy: .public)")
        return true
    }

    /// ✅ FIX: EA output.write() may return 0 temporarily; wait + retry (do NOT treat as fatal)
    private func writeCommand(_ command: String) throws {
        guard let output else { throw BLEManagerError.missingPeripheralOrCharacteristic }
        guard let data = "\(command)\r".data(using: .ascii) else { throw BLEManagerError.stringConversionFailed }

        post(.debug, "TX", meta: ["command": command])

        // EA streams often need a moment after open before accepting bytes.
        let start = CFAbsoluteTimeGetCurrent()
        let timeout: TimeInterval = 2.0

        try data.withUnsafeBytes { ptr in
            guard let base = ptr.bindMemory(to: UInt8.self).baseAddress else {
                throw BLEManagerError.incorrectDataConversion
            }

            var remaining = ptr.count
            var offset = 0

            while remaining > 0 {

                // Wait until output reports space
                while !output.hasSpaceAvailable {
                    if (CFAbsoluteTimeGetCurrent() - start) > timeout {
                        post(.error, "write timeout waiting for hasSpaceAvailable", meta: [
                            "command": command,
                            "outputStatus": "\(output.streamStatus.rawValue)",
                            "streamErr": output.streamError?.localizedDescription ?? "nil"
                        ])
                        throw BLEManagerError.sendMessageTimeout
                    }
                    Thread.sleep(forTimeInterval: 0.01)
                }

                let written = output.write(base.advanced(by: offset), maxLength: remaining)

                if written > 0 {
                    remaining -= written
                    offset += written
                    continue
                }

                if written == 0 {
                    // Not fatal: just means “try again soon”
                    if (CFAbsoluteTimeGetCurrent() - start) > timeout {
                        post(.error, "write returned 0 repeatedly (timeout)", meta: [
                            "command": command,
                            "outputStatus": "\(output.streamStatus.rawValue)",
                            "streamErr": output.streamError?.localizedDescription ?? "nil"
                        ])
                        throw BLEManagerError.sendMessageTimeout
                    }
                    Thread.sleep(forTimeInterval: 0.01)
                    continue
                }

                // written < 0 => real error
                post(.error, "write failed (<0)", meta: [
                    "command": command,
                    "written": "\(written)",
                    "outputStatus": "\(output.streamStatus.rawValue)",
                    "streamErr": output.streamError?.localizedDescription ?? "nil"
                ])
                throw output.streamError ?? BLEManagerError.sendMessageTimeout
            }
        }
    }

    /// Mirrors BLEMessageProcessor.waitForResponse(timeout:)
    private func waitForResponse(timeout: TimeInterval) async throws -> [String] {
        post(.debug, "waitForResponse start", meta: [
            "timeout_s": String(format: "%.2f", timeout),
            "lastCommand": lastCommand ?? "nil"
        ])

        do {
            let lines = try await withTimeout(seconds: timeout, timeoutError: BLEManagerError.timeout) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in

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

            post(.debug, "waitForResponse done", meta: ["lines": "\(lines.count)"])
            return lines
        } catch {
            post(.warning, "waitForResponse error", meta: [
                "error": error.localizedDescription,
                "lastCommand": lastCommand ?? "nil"
            ])
            throw error
        }
    }

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
            post(.warning, "NO DATA", meta: ["lastCommand": lastCommand ?? "nil"])
            completion(nil, BLEManagerError.noData)
        } else if lines.isEmpty {
            post(.warning, "empty response lines", meta: ["lastCommand": lastCommand ?? "nil"])
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
