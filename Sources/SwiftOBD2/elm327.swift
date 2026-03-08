//
//  ELM327.swift
//  SwiftOBD2
//
//  Updated:
//  ✅ Retries protocol probe when MX+ / EA returns transient CAN ERROR
//  ✅ Makes auto protocol detection less brittle
//  ✅ Adds small settle delay after ATZ and ATSP0
//  ✅ Keeps existing API/shape intact
//

import Combine
import CoreBluetooth
import Foundation
import OSLog

enum ELM327Error: Error, LocalizedError {
    case noProtocolFound
    case invalidResponse(message: String)
    case adapterInitializationFailed
    case ignitionOff
    case invalidProtocol
    case timeout
    case connectionFailed(reason: String)
    case unknownError

    var errorDescription: String? {
        switch self {
        case .noProtocolFound:
            return "No compatible OBD protocol found."
        case let .invalidResponse(message):
            return "Invalid response received: \(message)"
        case .adapterInitializationFailed:
            return "Failed to initialize adapter."
        case .ignitionOff:
            return "Vehicle ignition is off."
        case .invalidProtocol:
            return "Invalid or unsupported OBD protocol."
        case .timeout:
            return "Operation timed out."
        case let .connectionFailed(reason):
            return "Connection failed: \(reason)"
        case .unknownError:
            return "An unknown error occurred."
        }
    }
}

class ELM327 {
    var canProtocol: CANProtocol?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.example.com",
        category: "ELM327"
    )

    private var comm: CommProtocol
    private var cancellables = Set<AnyCancellable>()
    private var r100: [String] = []

    weak var obdDelegate: OBDServiceDelegate? {
        didSet {
            comm.obdDelegate = obdDelegate
        }
    }

    var connectionState: ConnectionState = .disconnected {
        didSet {
            obdDelegate?.connectionStateChanged(state: connectionState)
        }
    }

    init(comm: CommProtocol) {
        self.comm = comm
        setupConnectionStateSubscriber()
    }

    private func setupConnectionStateSubscriber() {
        comm.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.connectionState = state
                self?.obdDelegate?.connectionStateChanged(state: state)
                self?.logger.debug("Connection state updated: \(state.hashValue)")
            }
            .store(in: &cancellables)
    }

    // MARK: - Adapter and Vehicle Setup

    func setupVehicle(preferredProtocol: PROTOCOL?) async throws -> OBDInfo {
        let detectedProtocol = try await detectProtocol(preferredProtocol: preferredProtocol)

        canProtocol = protocols[detectedProtocol]

        let vin = await requestVin()
        let supportedPIDs = await getSupportedPIDs()

        guard let messages = try canProtocol?.parse(r100) else {
            throw ELM327Error.invalidResponse(message: "Invalid response to 0100")
        }

        let ecuMap = populateECUMap(messages)

        connectionState = .connectedToVehicle
        return OBDInfo(
            vin: vin,
            supportedPIDs: supportedPIDs,
            obdProtocol: detectedProtocol,
            ecuMap: ecuMap
        )
    }

    // MARK: - Protocol Selection

    private func detectProtocol(preferredProtocol: PROTOCOL? = nil) async throws -> PROTOCOL {
        logger.info("Starting protocol detection...")

        if let protocolToTest = preferredProtocol {
            logger.info("Attempting preferred protocol: \(protocolToTest.description, privacy: .public)")
            if await testProtocol(protocolToTest) {
                return protocolToTest
            } else {
                logger.warning("Preferred protocol \(protocolToTest.description, privacy: .public) failed. Falling back to automatic detection.")
            }
        } else {
            do {
                return try await detectProtocolAutomatically()
            } catch {
                logger.warning("Automatic protocol detection failed: \(error.localizedDescription, privacy: .public). Falling back to manual detection.")
                return try await detectProtocolManually()
            }
        }

        logger.error("Failed to detect a compatible OBD protocol.")
        throw ELM327Error.noProtocolFound
    }

    private func detectProtocolAutomatically() async throws -> PROTOCOL {
        logger.info("Attempting automatic protocol detection")

        _ = try await okResponse("ATSP0")
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        var last0100: [String] = []

        for attempt in 1...4 {
            do {
                logger.info("Auto-detect probe 0100 attempt \(attempt)")

                let response = try await sendCommand("0100", retries: 1)
                last0100 = response

                let joined = response.joined(separator: " | ")
                logger.info("Auto-detect 0100 response: \(joined, privacy: .public)")

                if response.contains(where: { $0.range(of: #"41\s*00"#, options: .regularExpression) != nil }) {
                    r100 = response

                    let obdProtocolNumber = try await sendCommand("ATDPN")

                    guard let first = obdProtocolNumber.first else {
                        throw ELM327Error.invalidResponse(message: "ATDPN returned empty response")
                    }

                    let cleaned = first
                        .replacingOccurrences(of: "A", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    guard let obdProtocol = PROTOCOL(rawValue: cleaned) else {
                        throw ELM327Error.invalidResponse(message: "Invalid protocol number: \(obdProtocolNumber)")
                    }

                    logger.info("Automatic protocol detection succeeded: \(obdProtocol.description, privacy: .public)")

                    // Re-test once so canProtocol/r100 are definitely aligned
                    _ = await testProtocol(obdProtocol)

                    return obdProtocol
                }

                if isRetryableProtocolProbeResponse(response) {
                    logger.warning("Auto-detect probe got retryable response on attempt \(attempt): \(joined, privacy: .public)")
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    continue
                }

                logger.warning("Auto-detect probe got non-valid response on attempt \(attempt): \(joined, privacy: .public)")
                try? await Task.sleep(nanoseconds: 500_000_000)

            } catch {
                logger.warning("Auto-detect probe failed on attempt \(attempt): \(error.localizedDescription, privacy: .public)")
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
        }

        logger.error("Automatic protocol detection failed after retries. Last 0100 response: \(last0100.joined(separator: " | "), privacy: .public)")
        throw ELM327Error.noProtocolFound
    }

    private func detectProtocolManually() async throws -> PROTOCOL {
        for protocolOption in PROTOCOL.allCases where protocolOption != .NONE {
            logger.info("Testing protocol: \(protocolOption.description, privacy: .public)")

            do {
                _ = try await okResponse(protocolOption.cmd)
                try? await Task.sleep(nanoseconds: 700_000_000)
            } catch {
                logger.warning("Failed to set protocol \(protocolOption.description, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }

            if await testProtocol(protocolOption) {
                return protocolOption
            }
        }

        logger.error("No protocol found")
        throw ELM327Error.noProtocolFound
    }

    // MARK: - Protocol Testing

    private func testProtocol(_ obdProtocol: PROTOCOL) async -> Bool {
        for attempt in 1...3 {
            let response = try? await sendCommand("0100", retries: 1)

            if let response = response {
                let joined = response.joined(separator: " | ")

                if response.contains(where: { $0.range(of: #"41\s*00"#, options: .regularExpression) != nil }) {
                    logger.info("Protocol \(obdProtocol.description, privacy: .public) is valid on attempt \(attempt).")
                    r100 = response
                    return true
                }

                if isRetryableProtocolProbeResponse(response) {
                    logger.warning("Protocol \(obdProtocol.description, privacy: .public) retryable probe response on attempt \(attempt): \(joined, privacy: .public)")
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    continue
                }

                logger.warning("Protocol \(obdProtocol.description, privacy: .public) invalid 0100 response on attempt \(attempt): \(joined, privacy: .public)")
                return false
            } else {
                logger.warning("Protocol \(obdProtocol.description, privacy: .public) test attempt \(attempt) returned nil response")
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }

        logger.warning("Protocol \(obdProtocol.description, privacy: .public) failed after retries.")
        return false
    }

    private func isRetryableProtocolProbeResponse(_ lines: [String]) -> Bool {
        let joined = lines
            .joined(separator: " ")
            .uppercased()

        return joined.contains("CAN ERROR")
            || joined.contains("UNABLE TO CONNECT")
            || joined.contains("BUS INIT")
            || joined.contains("BUS ERROR")
            || joined.contains("ERROR")
            || joined.contains("NO DATA")
    }

    // MARK: - Adapter Initialization

    func connectToAdapter(timeout: TimeInterval, peripheral: CBPeripheral? = nil) async throws {
        try await comm.connectAsync(timeout: timeout, peripheral: peripheral)
    }

    func adapterInitialization() async throws {
        logger.info("Initializing ELM327 adapter...")

        do {
            _ = try await sendCommand("ATZ")
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            _ = try await okResponse("ATE0")
            _ = try await okResponse("ATL0")
            _ = try await okResponse("ATS0")
            _ = try await okResponse("ATH1")
            _ = try await okResponse("ATSP0")

            try? await Task.sleep(nanoseconds: 600_000_000)

            logger.info("ELM327 adapter initialized successfully.")
        } catch {
            logger.error("Adapter initialization failed: \(error.localizedDescription, privacy: .public)")
            throw ELM327Error.adapterInitializationFailed
        }
    }

    private func setHeader(header: String) async throws {
        _ = try await okResponse("AT SH " + header)
    }

    func stopConnection() {
        comm.disconnectPeripheral()
        connectionState = .disconnected
    }

    // MARK: - Message Sending

    func sendCommand(_ message: String, retries: Int = 1) async throws -> [String] {
        try await comm.sendCommand(message, retries: retries)
    }

    private func okResponse(_ message: String) async throws -> [String] {
        let response = try await sendCommand(message)

        if response.contains(where: { $0.uppercased().contains("OK") }) {
            return response
        } else {
            logger.error("Invalid response for \(message, privacy: .public): \(response.joined(separator: " | "), privacy: .public)")
            throw ELM327Error.invalidResponse(
                message: "message: \(message), \(String(describing: response.first))"
            )
        }
    }

    func getStatus() async throws -> Result<DecodeResult, DecodeError> {
        logger.info("Getting status")
        let statusCommand = OBDCommand.Mode1.status
        let statusResponse = try await sendCommand(statusCommand.properties.command)
        logger.debug("Status response: \(statusResponse.joined(separator: " | "), privacy: .public)")

        guard let statusData = try canProtocol?.parse(statusResponse).first?.data else {
            return .failure(.noData)
        }

        return statusCommand.properties.decode(data: statusData)
    }

    func scanForTroubleCodes() async throws -> [ECUID: [TroubleCode]] {
        var dtcs: [ECUID: [TroubleCode]] = [:]

        logger.info("Scanning for trouble codes")
        let dtcCommand = OBDCommand.Mode3.GET_DTC
        let dtcResponse = try await sendCommand(dtcCommand.properties.command)

        guard let messages = try canProtocol?.parse(dtcResponse) else {
            return [:]
        }

        for message in messages {
            guard let dtcData = message.data else {
                continue
            }

            let decodedResult = dtcCommand.properties.decode(data: dtcData)
            let ecuId = message.ecu

            switch decodedResult {
            case let .success(result):
                dtcs[ecuId] = result.troubleCode
            case let .failure(error):
                logger.error("Failed to decode DTC: \(error.localizedDescription, privacy: .public)")
            }
        }

        return dtcs
    }

    func clearTroubleCodes() async throws {
        let command = OBDCommand.Mode4.CLEAR_DTC
        _ = try await sendCommand(command.properties.command)
    }

    func scanForPeripherals() async throws {
        try await comm.scanForPeripherals()
    }

    func requestVin() async -> String? {
        let command = OBDCommand.Mode9.VIN

        guard let vinResponse = try? await sendCommand(command.properties.command) else {
            return nil
        }

        guard let data = try? canProtocol?.parse(vinResponse).first?.data,
              var vinString = String(bytes: data, encoding: .utf8) else {
            return nil
        }

        vinString = vinString
            .replacingOccurrences(of: "[^a-zA-Z0-9]",
                                  with: "",
                                  options: .regularExpression)

        return vinString
    }
}

extension ELM327 {
    private func populateECUMap(_ messages: [MessageProtocol]) -> [UInt8: ECUID]? {
        let engineTXID = 0
        let transmissionTXID = 1
        var ecuMap: [UInt8: ECUID] = [:]

        guard !messages.isEmpty else {
            return nil
        }

        if messages.count == 1 {
            ecuMap[messages.first?.ecu.rawValue ?? 0] = .engine
            return ecuMap
        }

        var foundEngine = false

        for message in messages {
            let txID = message.ecu.rawValue

            if txID == engineTXID {
                ecuMap[txID] = .engine
                foundEngine = true
            } else if txID == transmissionTXID {
                ecuMap[txID] = .transmission
            }
        }

        if !foundEngine {
            var bestBits = 0
            var bestTXID: UInt8?

            for message in messages {
                guard let bits = message.data?.bitCount() else {
                    logger.error("parse_frame failed to extract data")
                    continue
                }

                if bits > bestBits {
                    bestBits = bits
                    bestTXID = message.ecu.rawValue
                }
            }

            if let bestTXID = bestTXID {
                ecuMap[bestTXID] = .engine
            }
        }

        for message in messages where ecuMap[message.ecu.rawValue] == nil {
            ecuMap[message.ecu.rawValue] = .transmission
        }

        return ecuMap
    }
}

extension ELM327 {

    func getSupportedPIDs() async -> [OBDCommand] {
        let pidGetters = OBDCommand.pidGetters
        var supportedPIDs: [OBDCommand] = []

        logger.info("Starting supported PID discovery (\(pidGetters.count) blocks)")

        for pidGetter in pidGetters {
            let block = sanitizeHex(pidGetter.properties.command)

            do {
                logger.debug("Requesting supported PID block \(block, privacy: .public)")
                let response = try await sendCommand(block)

                logger.debug("Raw ECU response \(block, privacy: .public): \(response.joined(separator: " | "), privacy: .public)")

                guard let supportedPidsByECU = parseSupportedPIDBlock(response, block: block) else {
                    logger.warning("No parsable PID data for block \(block, privacy: .public)")
                    continue
                }

                logger.info("ECU advertises \(supportedPidsByECU.count) PIDs for \(block, privacy: .public): \(supportedPidsByECU.sorted().joined(separator: ", "), privacy: .public)")

                let modePrefix = String(block.prefix(2))

                let supportedCommands = OBDCommand.allCommands.filter { cmd in
                    let cmdHex = self.sanitizeHex(cmd.properties.command)
                    guard cmdHex.hasPrefix(modePrefix), cmdHex.count >= 4 else { return false }
                    let pid = String(cmdHex.dropFirst(2))
                    return supportedPidsByECU.contains(pid)
                }

                logger.debug("Resolved commands for \(block, privacy: .public): \(supportedCommands.map { self.sanitizeHex($0.properties.command) }.joined(separator: ", "), privacy: .public)")

                supportedPIDs.append(contentsOf: supportedCommands)

            } catch {
                logger.error("PID block \(block, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        supportedPIDs = supportedPIDs.filter { !pidGetters.contains($0) }

        let unique = Array(Set(supportedPIDs))
        logger.info("Supported PID discovery complete: \(unique.count) total PIDs")

        return unique
    }

    private func parseSupportedPIDBlock(_ response: [String], block: String) -> Set<String>? {
        guard let ecuData = try? canProtocol?.parse(response).first?.data else {
            return nil
        }

        let binaryData = BitArray(data: ecuData.dropFirst()).binaryArray
        return extractSupportedPIDs(binaryData, block: block)
    }

    func extractSupportedPIDs(_ binaryData: [Int], block: String) -> Set<String> {
        var supported: Set<String> = []

        let blockHex = sanitizeHex(block)

        let base: Int
        switch blockHex {
        case "0100": base = 0x00
        case "0120": base = 0x20
        case "0140": base = 0x40
        case "0160": base = 0x60
        case "0180": base = 0x80
        case "01A0": base = 0xA0
        case "01C0": base = 0xC0
        case "0900": base = 0x00
        default:
            base = 0x00
            logger.warning("Unknown PID block \(blockHex, privacy: .public) (default base=0)")
        }

        for (index, bit) in binaryData.enumerated() where bit == 1 {
            let pidValue = base + index + 1
            supported.insert(String(format: "%02X", pidValue))
        }

        logger.debug("Extracted supported PIDs \(blockHex, privacy: .public): \(supported.sorted().joined(separator: ", "), privacy: .public)")

        return supported
    }

    private func sanitizeHex(_ s: String) -> String {
        s.uppercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: ">", with: "")
    }
}

struct BatchedResponse {
    private var response: Data
    private var unit: MeasurementUnit

    init(response: Data, _ unit: MeasurementUnit) {
        self.response = response
        self.unit = unit
    }

    mutating func extractValue(_ cmd: OBDCommand) -> MeasurementResult? {
        let properties = cmd.properties
        let size = properties.bytes

        guard response.count >= size else { return nil }

        let valueData = response.prefix(size)
        response.removeFirst(size)

        let result = cmd.properties.decode(data: valueData, unit: unit)

        switch result {
        case let .success(measurementResult):
            return measurementResult.measurementResult
        case let .failure(error):
            obdError(
                "Failed to decode command \(cmd.properties.command): \(error.localizedDescription) | Data: \(valueData.map { String(format: "%02X", $0) }.joined(separator: " "))",
                category: .parsing
            )
            return nil
        }
    }
}

extension String {
    var hexBytes: [UInt8] {
        var position = startIndex
        return (0 ..< count / 2).compactMap { _ in
            defer { position = index(position, offsetBy: 2) }
            return UInt8(self[position ... index(after: position)], radix: 16)
        }
    }

    var isHex: Bool {
        !isEmpty && allSatisfy(\.isHexDigit)
    }
}

extension Data {
    func bitCount() -> Int {
        count * 8
    }
}

enum ECUHeader {
    static let ENGINE = "7E0"
}

public struct OBDInfo: Codable, Hashable {
    public var vin: String?
    public var supportedPIDs: [OBDCommand]?
    public var obdProtocol: PROTOCOL?
    public var ecuMap: [UInt8: ECUID]?
}
