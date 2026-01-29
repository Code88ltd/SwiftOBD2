//
//  ELM327.swift
//  SwiftOBD2
//
//  NOTE:
//  ✅ This file contains ZERO references to the host app (e.g. LogStore).
//  ✅ Logging is bridged to the app via postOBDLogEvent(...), which your app listens for
//     and forwards into LogStore.shared.
//  ✅ Full copy/paste file.
//
//  Author: Kemo Konteh (original) + fixes applied
//

import Combine
import CoreBluetooth
import Foundation
import OSLog

// MARK: - ELM327 Errors

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

// MARK: - ELM327 Class

final class ELM327 {
    // Protocol parser chosen after detection
    var canProtocol: CANProtocol?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "SwiftOBD2",
        category: "ELM327"
    )

    private let comm: CommProtocol
    private var cancellables = Set<AnyCancellable>()

    weak var obdDelegate: OBDServiceDelegate? {
        didSet { comm.obdDelegate = obdDelegate }
    }

    /// Cached 0100 response used for ECU map population
    private var r100: [String] = []

    var connectionState: ConnectionState = .disconnected {
        didSet { obdDelegate?.connectionStateChanged(state: connectionState) }
    }

    init(comm: CommProtocol) {
        self.comm = comm
        setupConnectionStateSubscriber()
    }

    private func setupConnectionStateSubscriber() {
        comm.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                self.connectionState = state
                self.obdDelegate?.connectionStateChanged(state: state)
                self.logger.debug("Connection state updated: \(state.rawValue)")
                postOBDLogEvent(level: "debug", category: .connection, message: "Connection state: \(state.rawValue)")
            }
            .store(in: &cancellables)
    }

    // MARK: - Adapter and Vehicle Setup

    /// Sets up the vehicle connection, including automatic protocol detection.
    /// - Parameter preferredProtocol: Optional preferred protocol to try first.
    /// - Returns: OBDInfo containing VIN, supported PIDs, protocol, and ECU map.
    func setupVehicle(preferredProtocol: PROTOCOL?) async throws -> OBDInfo {

        postOBDLogEvent(level: "info", category: .connection, message: "Starting vehicle setup…")

        let detectedProtocol = try await detectProtocol(preferredProtocol: preferredProtocol)
        canProtocol = protocols[detectedProtocol]

        let vin = await requestVin()

        // Discover supported PIDs (logs are bridged to host app)
        let supportedPIDs = await getSupportedPIDs()

        guard let messages = try canProtocol?.parse(r100) else {
            postOBDLogEvent(level: "error", category: .parsing, message: "Invalid response to 0100 (cannot parse)")
            throw ELM327Error.invalidResponse(message: "Invalid response to 0100")
        }

        let ecuMap = populateECUMap(messages)

        connectionState = .connectedToVehicle
        postOBDLogEvent(level: "info", category: .connection, message: "Vehicle setup complete. Protocol=\(detectedProtocol.description) VIN=\(vin ?? "nil")")

        return OBDInfo(
            vin: vin,
            supportedPIDs: supportedPIDs,
            obdProtocol: detectedProtocol,
            ecuMap: ecuMap
        )
    }

    // MARK: - Protocol Selection

    private func detectProtocol(preferredProtocol: PROTOCOL? = nil) async throws -> PROTOCOL {
        logger.info("Starting protocol detection…")
        postOBDLogEvent(level: "info", category: .connection, message: "Starting protocol detection…")

        if let protocolToTest = preferredProtocol {
            logger.info("Attempting preferred protocol: \(protocolToTest.description)")
            postOBDLogEvent(level: "debug", category: .connection, message: "Trying preferred protocol: \(protocolToTest.description)")

            if await testProtocol(protocolToTest) {
                postOBDLogEvent(level: "info", category: .connection, message: "Preferred protocol OK: \(protocolToTest.description)")
                return protocolToTest
            }

            logger.warning("Preferred protocol failed. Falling back…")
            postOBDLogEvent(level: "warning", category: .connection, message: "Preferred protocol failed. Falling back…")
        }

        do {
            let p = try await detectProtocolAutomatically()
            postOBDLogEvent(level: "info", category: .connection, message: "Auto protocol detected: \(p.description)")
            return p
        } catch {
            let p = try await detectProtocolManually()
            postOBDLogEvent(level: "info", category: .connection, message: "Manual protocol detected: \(p.description)")
            return p
        }
    }

    private func detectProtocolAutomatically() async throws -> PROTOCOL {
        _ = try await okResponse("ATSP0")
        try? await Task.sleep(nanoseconds: 800_000_000)

        _ = try await sendCommand("0100")

        let obdProtocolNumber = try await sendCommand("ATDPN")
        guard let first = obdProtocolNumber.first else {
            throw ELM327Error.invalidResponse(message: "Empty ATDPN response")
        }

        // ATDPN usually returns like "A6" or "06" etc; original used dropFirst()
        let protoRaw = String(first.dropFirst())
        guard let obdProtocol = PROTOCOL(rawValue: protoRaw) else {
            throw ELM327Error.invalidResponse(message: "Invalid protocol number: \(obdProtocolNumber)")
        }

        _ = await testProtocol(obdProtocol)
        return obdProtocol
    }

    private func detectProtocolManually() async throws -> PROTOCOL {
        for proto in PROTOCOL.allCases where proto != .NONE {
            logger.info("Testing protocol: \(proto.description)")
            postOBDLogEvent(level: "debug", category: .connection, message: "Testing protocol: \(proto.description)")

            _ = try await okResponse(proto.cmd)
            if await testProtocol(proto) {
                return proto
            }
        }

        logger.error("No protocol found")
        postOBDLogEvent(level: "error", category: .connection, message: "No protocol found")
        throw ELM327Error.noProtocolFound
    }

    private func testProtocol(_ proto: PROTOCOL) async -> Bool {
        let response = try? await sendCommand("0100", retries: 3)

        if let response,
           response.contains(where: { $0.range(of: #"41\s*00"#, options: .regularExpression) != nil }) {
            logger.info("Protocol \(proto.description) is valid.")
            postOBDLogEvent(level: "info", category: .connection, message: "Protocol valid: \(proto.description)")

            r100 = response
            return true
        } else {
            logger.warning("Protocol \(proto.rawValue) did not return valid 0100 response.")
            postOBDLogEvent(level: "warning", category: .connection, message: "Protocol invalid: \(proto.description) (no 41 00)")
            return false
        }
    }

    // MARK: - Adapter Initialization

    func connectToAdapter(timeout: TimeInterval, peripheral: CBPeripheral? = nil) async throws {
        try await comm.connectAsync(timeout: timeout, peripheral: peripheral)
    }

    func adapterInitialization() async throws {
        logger.info("Initializing ELM327 adapter…")
        postOBDLogEvent(level: "info", category: .connection, message: "Initializing adapter…")

        do {
            _ = try await sendCommand("ATZ")   // Reset adapter
            _ = try await okResponse("ATE0")   // Echo off
            _ = try await okResponse("ATL0")   // Linefeeds off
            _ = try await okResponse("ATS0")   // Spaces off
            _ = try await okResponse("ATH1")   // Headers on (per your mock framework)
            _ = try await okResponse("ATSP0")  // Auto protocol

            logger.info("Adapter initialized OK")
            postOBDLogEvent(level: "info", category: .connection, message: "Adapter initialized OK")
        } catch {
            logger.error("Adapter initialization failed: \(error.localizedDescription)")
            postOBDLogEvent(level: "error", category: .connection, message: "Adapter init failed: \(error.localizedDescription)")
            throw ELM327Error.adapterInitializationFailed
        }
    }

    private func setHeader(header: String) async throws {
        _ = try await okResponse("AT SH " + header)
    }

    func stopConnection() {
        comm.disconnectPeripheral()
        connectionState = .disconnected
        postOBDLogEvent(level: "info", category: .connection, message: "Disconnected")
    }

    // MARK: - Message Sending

    func sendCommand(_ message: String, retries: Int = 1) async throws -> [String] {
        try await comm.sendCommand(message, retries: retries)
    }

    private func okResponse(_ message: String) async throws -> [String] {
        let response = try await sendCommand(message)
        if response.contains("OK") {
            return response
        } else {
            logger.error("Invalid response: \(response)")
            throw ELM327Error.invalidResponse(message: "message: \(message), \(String(describing: response.first))")
        }
    }

    // MARK: - Status / DTC / VIN

    func getStatus() async throws -> Result<DecodeResult, DecodeError> {
        logger.info("Getting status")
        postOBDLogEvent(level: "debug", category: .communication, message: "Requesting status (0101)")

        let statusCommand = OBDCommand.Mode1.status
        let statusResponse = try await sendCommand(statusCommand.properties.command)

        logger.debug("Status response: \(statusResponse)")
        postOBDLogEvent(level: "debug", category: .communication, message: "Status raw: \(statusResponse.joined(separator: " | "))")

        guard let statusData = try canProtocol?.parse(statusResponse).first?.data else {
            postOBDLogEvent(level: "warning", category: .parsing, message: "Status parse: NO DATA")
            return .failure(.noData)
        }

        return statusCommand.properties.decode(data: statusData)
    }

    func scanForTroubleCodes() async throws -> [ECUID: [TroubleCode]] {
        var dtcs: [ECUID: [TroubleCode]] = [:]

        logger.info("Scanning for trouble codes")
        postOBDLogEvent(level: "info", category: .communication, message: "Scanning trouble codes (Mode 03)")

        let dtcCommand = OBDCommand.Mode3.GET_DTC
        let dtcResponse = try await sendCommand(dtcCommand.properties.command)

        postOBDLogEvent(level: "debug", category: .communication, message: "DTC raw: \(dtcResponse.joined(separator: " | "))")

        guard let messages = try canProtocol?.parse(dtcResponse) else {
            postOBDLogEvent(level: "warning", category: .parsing, message: "DTC parse failed (no frames)")
            return [:]
        }

        for message in messages {
            guard let dtcData = message.data else { continue }

            let decodedResult = dtcCommand.properties.decode(data: dtcData)
            let ecuId = message.ecu

            switch decodedResult {
            case let .success(result):
                dtcs[ecuId] = result.troubleCode
            case let .failure(error):
                logger.error("Failed to decode DTC: \(error.localizedDescription)")
                postOBDLogEvent(level: "warning", category: .parsing, message: "DTC decode failed: \(error.localizedDescription)")
            }
        }

        return dtcs
    }

    func clearTroubleCodes() async throws {
        postOBDLogEvent(level: "info", category: .communication, message: "Clearing trouble codes (Mode 04)")
        let command = OBDCommand.Mode4.CLEAR_DTC
        _ = try await sendCommand(command.properties.command)
    }

    func scanForPeripherals() async throws {
        try await comm.scanForPeripherals()
    }

    func requestVin() async -> String? {
        postOBDLogEvent(level: "debug", category: .communication, message: "Requesting VIN (Mode 09)")
        let command = OBDCommand.Mode9.VIN

        guard let vinResponse = try? await sendCommand(command.properties.command) else {
            postOBDLogEvent(level: "warning", category: .communication, message: "VIN request failed (no response)")
            return nil
        }

        guard let data = try? canProtocol?.parse(vinResponse).first?.data,
              var vinString = String(bytes: data, encoding: .utf8)
        else {
            postOBDLogEvent(level: "warning", category: .parsing, message: "VIN parse failed")
            return nil
        }

        vinString = vinString.replacingOccurrences(
            of: "[^a-zA-Z0-9]",
            with: "",
            options: .regularExpression
        )

        postOBDLogEvent(level: "info", category: .communication, message: "VIN: \(vinString)")
        return vinString
    }
}

// MARK: - ECU Map (unchanged logic)

extension ELM327 {
    private func populateECUMap(_ messages: [MessageProtocol]) -> [UInt8: ECUID]? {
        let engineTXID = 0
        let transmissionTXID = 1
        var ecuMap: [UInt8: ECUID] = [:]

        guard !messages.isEmpty else { return nil }

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

// MARK: - Supported PIDs (FIXED: no LogStore references)

extension ELM327 {

    /// Discover supported PIDs across blocks (0100, 0120, ...).
    /// Emits logs via postOBDLogEvent so the host app can display them.
    func getSupportedPIDs() async -> [OBDCommand] {
        let pidGetters = OBDCommand.pidGetters
        var supportedPIDs: [OBDCommand] = []

        postOBDLogEvent(
            level: "info",
            category: .communication,
            message: "Starting supported PID discovery (\(pidGetters.count) blocks)"
        )

        for pidGetter in pidGetters {
            let block = pidGetter.properties.command

            do {
                postOBDLogEvent(level: "debug", category: .communication, message: "Requesting supported PID block \(block)")
                let response = try await sendCommand(block)

                postOBDLogEvent(
                    level: "debug",
                    category: .communication,
                    message: "Raw ECU response \(block): \(response.joined(separator: " | "))"
                )

                guard let supportedPidsByECU = parseSupportedPIDBlock(response, block: block) else {
                    postOBDLogEvent(level: "warning", category: .parsing, message: "No parsable PID data for block \(block)")
                    continue
                }

                postOBDLogEvent(
                    level: "info",
                    category: .communication,
                    message: "ECU advertises \(supportedPidsByECU.count) PIDs for \(block): \(supportedPidsByECU.sorted().joined(separator: ", "))"
                )

                let supportedCommands = OBDCommand.allCommands.filter {
                    supportedPidsByECU.contains(String($0.properties.command.dropFirst(2)))
                }

                postOBDLogEvent(
                    level: "debug",
                    category: .communication,
                    message: "Resolved commands for \(block): \(supportedCommands.map { $0.properties.command }.joined(separator: ", "))"
                )

                supportedPIDs.append(contentsOf: supportedCommands)

            } catch {
                postOBDLogEvent(level: "error", category: .communication, message: "PID block \(block) failed: \(error.localizedDescription)")
            }
        }

        supportedPIDs = supportedPIDs.filter { !pidGetters.contains($0) }
        let unique = Array(Set(supportedPIDs))

        postOBDLogEvent(level: "info", category: .communication, message: "Supported PID discovery complete: \(unique.count) total PIDs")
        return unique
    }

    /// Parse one supported-PID block response into a set of PID hex strings ("01"..."20" etc),
    /// adjusted for the block (0100, 0120, 0140...).
    private func parseSupportedPIDBlock(_ response: [String], block: String) -> Set<String>? {
        guard let ecuData = try? canProtocol?.parse(response).first?.data else {
            return nil
        }

        // Drop the first byte like your earlier approach; BitArray is expected in the module.
        let binaryData = BitArray(data: ecuData.dropFirst()).binaryArray
        return extractSupportedPIDs(binaryData, block: block)
    }

    /// Converts the 32-bit map into PIDs for the requested block.
    ///
    /// block mapping:
    /// 0100 => base 0x00 (PIDs 01-20)
    /// 0120 => base 0x20 (PIDs 21-40)
    /// 0140 => base 0x40 (PIDs 41-60)
    /// 0160 => base 0x60 (PIDs 61-80)
    /// 0180 => base 0x80 (PIDs 81-A0)
    /// 01A0 => base 0xA0 (PIDs A1-C0)
    /// 01C0 => base 0xC0 (PIDs C1-E0)
    func extractSupportedPIDs(_ binaryData: [Int], block: String) -> Set<String> {
        var supported: Set<String> = []

        let base: Int
        switch block.cleanedHex.uppercased() {
        case "0100": base = 0x00
        case "0120": base = 0x20
        case "0140": base = 0x40
        case "0160": base = 0x60
        case "0180": base = 0x80
        case "01A0": base = 0xA0
        case "01C0": base = 0xC0
        default:
            base = 0x00
            postOBDLogEvent(level: "warning", category: .parsing, message: "Unknown PID block \(block) (default base=0)")
        }

        for (index, value) in binaryData.enumerated() where value == 1 {
            let pidValue = base + index + 1
            supported.insert(String(format: "%02X", pidValue))
        }

        postOBDLogEvent(
            level: "debug",
            category: .parsing,
            message: "Extracted supported PIDs \(block): \(supported.sorted().joined(separator: ", "))"
        )

        return supported
    }
}

// MARK: - BatchedResponse (unchanged)

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
            postOBDLogEvent(
                level: "warning",
                category: .parsing,
                message: "Decode failed for \(cmd.properties.command): \(error.localizedDescription)"
            )
            return nil
        }
    }
}

// MARK: - Small Utilities (unchanged)

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

    /// If you already have this in the module elsewhere, this duplicates harmlessly.
    var cleanedHex: String {
        uppercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: ">", with: "")
    }
}

extension Data {
    func bitCount() -> Int { count * 8 }
}

enum ECUHeader {
    static let ENGINE = "7E0"
}

// MARK: - OBDInfo

public struct OBDInfo: Codable, Hashable {
    public var vin: String?
    public var supportedPIDs: [OBDCommand]?
    public var obdProtocol: PROTOCOL?
    public var ecuMap: [UInt8: ECUID]?
}
