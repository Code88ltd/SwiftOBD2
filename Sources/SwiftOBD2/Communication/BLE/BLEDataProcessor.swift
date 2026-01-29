import Combine
import CoreBluetooth
import Foundation
import OSLog

// MARK: - Simple async lock to prevent concurrent commands
actor AsyncLock {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    func unlock() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            let next = waiters.removeFirst()
            next.resume()
        }
    }
}

final class BLEMessageProcessor {

    private var buffer = Data()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.example.app",
        category: "BLEMessageProcessor"
    )

    // Single in-flight completion (protected by commandLock)
    private var messageCompletion: (([String]?, Error?) -> Void)?

    // ✅ Prevent concurrent requests (Dashboard + CarPlay etc.)
    private let commandLock = AsyncLock()

    // MARK: - Incoming BLE data

    func processReceivedData(_ data: Data) {
        buffer.append(data)

        guard let string = String(data: buffer, encoding: .utf8) else {
            // Only clear if buffer is getting too large
            if buffer.count > BLEConstants.maxBufferSize {
                logger.warning("Buffer exceeded max size, clearing")
                buffer.removeAll()
            }
            return
        }

        // End-of-response marker
        if string.contains(">") {
            let response = parseResponse(from: string)
            handleParsedResponse(response)
            buffer.removeAll()
        }
    }

private func parseResponse(from string: String) -> [String] {
    let cleaned = string.replacingOccurrences(of: ">", with: "")

    let lines = cleaned
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    LogStore.shared.debug(
        "ELM327",
        """
        Raw ELM response:
        \(string)

        Parsed lines:
        \(lines.joined(separator: " | "))
        """
    )

    return lines
}

    private func handleParsedResponse(_ lines: [String]) {
        let completion = messageCompletion
        messageCompletion = nil

        guard let completion else {
            logger.warning("Received response with no pending completion")
            return
        }

        if let firstLine = lines.first, firstLine.uppercased().contains("NO DATA") {
            completion(nil, BLEManagerError.noData)
        } else if lines.isEmpty {
            completion(nil, BLEManagerError.noData)
        } else {
            completion(lines, nil)
        }
    }

    // MARK: - Await a response (serialized)

    func waitForResponse(timeout: TimeInterval) async throws -> [String] {
        // ✅ Serialize all callers so messageCompletion is never overwritten
        await commandLock.lock()
        defer { Task { await commandLock.unlock() } }

        return try await withTimeout(
            seconds: timeout,
            timeoutError: BLEMessageProcessorError.responseTimeout
        ) { [self] in

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in

                // Defensive (should never happen due to lock)
                if messageCompletion != nil {
                    logger.error("waitForResponse called while another command is pending")
                    continuation.resume(throwing: BLEMessageProcessorError.concurrentCommand)
                    return
                }

                messageCompletion = { response, error in
                    // Ensure we don't hold onto completion
                    self.messageCompletion = nil

                    if let response = response {
                        continuation.resume(returning: response)
                    } else if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(throwing: BLEMessageProcessorError.responseTimeout)
                    }
                }
            }
        }
    }

    // MARK: - Reset

    func reset() {
        buffer.removeAll()

        let completion = messageCompletion
        messageCompletion = nil

        // Unblock anyone waiting
        completion?(nil, BLEManagerError.peripheralNotConnected)
    }
}

// MARK: - Error Types

enum BLEMessageProcessorError: Error, LocalizedError {
    case characteristicNotWritable
    case writeOperationFailed
    case responseTimeout
    case invalidResponseData
    case concurrentCommand

    var errorDescription: String? {
        switch self {
        case .characteristicNotWritable:
            return "BLE characteristic does not support write operations"
        case .writeOperationFailed:
            return "Failed to write data to BLE characteristic"
        case .responseTimeout:
            return "Timeout waiting for BLE response"
        case .invalidResponseData:
            return "Received invalid response data from BLE device"
        case .concurrentCommand:
            return "Another BLE command is already waiting for a response"
        }
    }
}
