import Foundation
import ExternalAccessory
import OSLog
import CoreBluetooth   // Only here because CommProtocol references CBPeripheral

final class ExternalAccessoryManager: NSObject, CommProtocol, StreamDelegate {

    // MARK: - CommProtocol requirements
    @Published var connectionState: ConnectionState = .disconnected
    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }
    var obdDelegate: OBDServiceDelegate?

    // MARK: - Config
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.app",
                                category: "ExternalAccessoryManager")
    private let protocolString = "com.obdlink"

    // MARK: - EA session
    private var accessory: EAAccessory?
    private var session: EASession?
    private var input: InputStream?
    private var output: OutputStream?

    // MARK: - IO buffering
    private let ioQueue = DispatchQueue(label: "ExternalAccessoryManager.ioQueue")
    private var rxBuffer = Data()

    // Pending command continuation (we only allow 1 in-flight command)
    private var pendingContinuation: CheckedContinuation<[String], Error>?
    private var pendingTimeoutTask: Task<Void, Never>?

    // MARK: - Init
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
        connectionState = .connecting

        // ExternalAccessory: device must already be paired/connected at OS level
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if try openSessionIfAvailable() {
                connectionState = .connectedToAdapter
                obdDelegate?.connectionStateChanged(state: .connectedToAdapter)
                return
            }
            try await Task.sleep(nanoseconds: 250_000_000) // 250ms
        }

        connectionState = .disconnected
        throw CommunicationError.invalidData
    }

    func disconnectPeripheral() {
        ioQueue.sync {
            pendingTimeoutTask?.cancel()
            pendingTimeoutTask = nil

            if let cont = pendingContinuation {
                pendingContinuation = nil
                cont.resume(throwing: CommunicationError.invalidData)
            }

            input?.close()
            output?.close()
            input?.remove(from: .current, forMode: .default)
            output?.remove(from: .current, forMode: .default)
            input?.delegate = nil
            output?.delegate = nil

            input = nil
            output = nil
            session = nil
            accessory = nil
            rxBuffer.removeAll()
        }

        connectionState = .disconnected
        obdDelegate?.connectionStateChanged(state: .disconnected)
    }

    func scanForPeripherals() async throws {
        // No scanning in ExternalAccessory.
        // Leave as no-op to match WifiManager.
    }

    func sendCommand(_ command: String, retries: Int) async throws -> [String] {
        guard let data = "\(command)\r".data(using: .ascii) else {
            throw CommunicationError.invalidData
        }

        logger.info("Sending (EA): \(command, privacy: .public)")

        for attempt in 1...max(1, retries) {
            do {
                return try await sendCommandInternal(data: data, timeout: 2.5)
            } catch {
                if attempt == retries { throw error }
                logger.warning("Attempt \(attempt) failed, retrying: \(error.localizedDescription, privacy: .public)")
                try await Task.sleep(nanoseconds: 100_000_000) // 0.1s
            }
        }

        throw CommunicationError.invalidData
    }

    // MARK: - Internals

    private func openSessionIfAvailable() throws -> Bool {
        let accessories = EAAccessoryManager.shared().connectedAccessories
        guard let acc = accessories.first(where: { $0.protocolStrings.contains(protocolString) }) else {
            return false
        }

        accessory = acc

        guard let sess = EASession(accessory: acc, forProtocol: protocolString) else {
            logger.error("Failed to create EASession")
            throw CommunicationError.invalidData
        }

        session = sess
        input = sess.inputStream
        output = sess.outputStream

        input?.delegate = self
        output?.delegate = self

        input?.schedule(in: .current, forMode: .default)
        output?.schedule(in: .current, forMode: .default)

        input?.open()
        output?.open()

        logger.info("EA session opened: \(acc.name, privacy: .public)")
        return true
    }

    private func ensureReady() throws {
        guard connectionState == .connectedToAdapter,
              let input, let output,
              input.streamStatus == .open || input.streamStatus == .reading,
              output.streamStatus == .open || output.streamStatus == .writing
        else {
            throw CommunicationError.invalidData
        }
    }

    private func sendCommandInternal(data: Data, timeout: TimeInterval) async throws -> [String] {
        try ensureReady()

        // Serialize: only one in-flight command at a time
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
            ioQueue.async {
                if self.pendingContinuation != nil {
                    continuation.resume(throwing: CommunicationError.invalidData)
                    return
                }

                // Reset per-command receive buffer
                self.rxBuffer.removeAll()
                self.pendingContinuation = continuation

                // Timeout
                self.pendingTimeoutTask?.cancel()
                self.pendingTimeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    guard let self else { return }
                    self.ioQueue.async {
                        if let cont = self.pendingContinuation {
                            self.pendingContinuation = nil
                            self.logger.error("EA command timeout")
                            cont.resume(throwing: ELM327Error.timeout)
                        }
                    }
                }

                // Write
                data.withUnsafeBytes { ptr in
                    guard let base = ptr.bindMemory(to: UInt8.self).baseAddress else {
                        self.finishWithError(CommunicationError.invalidData)
                        return
                    }
                    var remaining = ptr.count
                    var offset = 0
                    while remaining > 0 {
                        let written = self.output?.write(base.advanced(by: offset), maxLength: remaining) ?? -1
                        if written <= 0 {
                            self.finishWithError(CommunicationError.invalidData)
                            return
                        }
                        remaining -= written
                        offset += written
                    }
                }
            }
        }
    }

    private func finishIfComplete() {
        // ELM style ends with ">" prompt.
        // Parse as UTF-8/ASCII text and wait until we see ">"
        guard let text = String(data: rxBuffer, encoding: .utf8) ?? String(data: rxBuffer, encoding: .ascii) else {
            return
        }

        guard text.contains(">") else { return }

        pendingTimeoutTask?.cancel()
        pendingTimeoutTask = nil

        let lines = processResponse(text)

        guard let cont = pendingContinuation else { return }
        pendingContinuation = nil

        if let lines {
            cont.resume(returning: lines)
        } else {
            cont.resume(throwing: CommunicationError.invalidData)
        }
    }

    private func finishWithError(_ error: Error) {
        pendingTimeoutTask?.cancel()
        pendingTimeoutTask = nil

        guard let cont = pendingContinuation else { return }
        pendingContinuation = nil
        cont.resume(throwing: error)
    }

    // Mirrors WifiManager.processResponse(_:)
    private func processResponse(_ response: String) -> [String]? {
        logger.info("Processing EA response: \(response, privacy: .public)")

        var lines = response
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else {
            logger.warning("Empty response lines")
            return nil
        }

        // Remove prompt line or trailing ">"
        if let last = lines.last, last.contains(">") {
            lines.removeLast()
        } else {
            // Sometimes ">" is appended to last line
            if let i = lines.indices.last, lines[i].contains(">") {
                lines[i] = lines[i].replacingOccurrences(of: ">", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if lines[i].isEmpty { lines.removeLast() }
            }
        }

        // Handle "NO DATA"
        if lines.first?.lowercased() == "no data" {
            return nil
        }

        // Some adapters still echo; you *usually* send ATE0, but be defensive:
        // if first line equals the command, you can strip in your higher layer (optional)

        return lines
    }

    // MARK: - StreamDelegate
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable:
            guard aStream === input else { return }
            readAvailable()
        case .endEncountered, .errorOccurred:
            logger.warning("EA stream ended/error")
            disconnectPeripheral()
        default:
            break
        }
    }

    private func readAvailable() {
        guard let input else { return }

        var buf = [UInt8](repeating: 0, count: 4096)
        while input.hasBytesAvailable {
            let n = input.read(&buf, maxLength: buf.count)
            if n > 0 {
                ioQueue.async {
                    self.rxBuffer.append(contentsOf: buf[0..<n])
                    self.finishIfComplete()
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
