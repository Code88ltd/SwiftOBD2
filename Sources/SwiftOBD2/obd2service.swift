//
//  OBDService.swift
//  BLE
//
//  LOGGING UPGRADE (copy/paste):
//  ✅ Adds a single, consistent telemetry logger `t(...)`
//  ✅ Emits correlation ids: connectId + requestId
//  ✅ Logs connection type, preferred protocol, timeout
//  ✅ Logs lifecycle milestones + durations (adapter connect/init/vehicle setup)
//  ✅ Logs transport selection (BLE/WiFi/EA/Demo) and blocks BLE-only actions when EA selected
//  ✅ Logs mapped errors with stable codes (no SwiftOBD2 type names in *messages*)
//  ✅ Adds optional “wire” logging for TX/RX (already present) + captures raw errors
//
//  To enable sending to Supabase:
//  - Set `obdService.telemetrySink = { event in ... }` in your app (AppContainer / App).
//

import Combine
import CoreBluetooth
import Foundation

public enum ConnectionType: String, CaseIterable {
    case bluetooth = "Bluetooth"
    case wifi = "Wi-Fi"
    case externalAccessory = "OBDLink (EA)"
    case demo = "Demo"
}

public protocol OBDServiceDelegate: AnyObject {
    func connectionStateChanged(state: ConnectionState)
}

struct Command: Codable {
    var bytes: Int
    var command: String
    var decoder: String
    var description: String
    var live: Bool
    var maxValue: Int
    var minValue: Int
}

public class ConfigurationService {
    public static var shared = ConfigurationService()
    public var connectionType: ConnectionType {
        get {
            let rawValue = UserDefaults.standard.string(forKey: "connectionType") ?? ConnectionType.bluetooth.rawValue
            return ConnectionType(rawValue: rawValue) ?? .bluetooth
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "connectionType")
        }
    }
}

// MARK: - ✅ Single request gate (prevents interleaved responses)
public actor OBDRequestLock {
    private var isLocked = false
    public init() {}

    public func withLock<T>(_ op: () async throws -> T) async throws -> T {
        while isLocked {
            try await Task.sleep(nanoseconds: 5_000_000) // 5ms
        }
        isLocked = true
        defer { isLocked = false }
        return try await op()
    }
}

// MARK: - Telemetry hook (optional)
public struct OBDTelemetryEvent: Sendable {
    public let level: String          // "debug" | "info" | "warning" | "error"
    public let category: String       // "connection" | "communication" etc
    public let message: String
    public let meta: [String: String]?
    public init(level: String, category: String, message: String, meta: [String: String]? = nil) {
        self.level = level
        self.category = category
        self.message = message
        self.meta = meta
    }
}
public typealias OBDTelemetrySink = @Sendable (OBDTelemetryEvent) -> Void

/// A class that provides an interface to the ELM327 OBD2 adapter and the vehicle.
public final class OBDService: ObservableObject, OBDServiceDelegate {

    @Published public private(set) var connectionState: ConnectionState = .disconnected
    @Published public private(set) var isScanning: Bool = false
    @Published public private(set) var connectedPeripheral: CBPeripheral?

    @Published public var connectionType: ConnectionType {
        didSet {
            t(.info, "connectionType changed", meta: [
                "from": oldValue.rawValue,
                "to": connectionType.rawValue
            ])
            switchConnectionType(connectionType)
            ConfigurationService.shared.connectionType = connectionType
        }
    }

    /// Optional telemetry sink (set by app)
    public var telemetrySink: OBDTelemetrySink?

    /// The internal ELM327 object responsible for direct adapter interaction.
    private var elm327: ELM327

    private var cancellables = Set<AnyCancellable>()
    private let requestLock = OBDRequestLock()

    // MARK: - Correlation IDs
    private var connectId: String = ""
    private var requestCounter: UInt64 = 0
    private func nextRequestID() -> UInt64 {
        requestCounter &+= 1
        return requestCounter
    }

    // MARK: - Telemetry helper

    private enum L: String { case debug, info, warning, error }

    private func t(_ level: L, _ message: String, category: String = "obd", meta: [String: String]? = nil) {
        var m = meta ?? [:]
        if !connectId.isEmpty { m["connectId"] = connectId }
        m["connectionType"] = connectionType.rawValue
        m["connectionState"] = "\(connectionState)"
        telemetrySink?(OBDTelemetryEvent(level: level.rawValue, category: category, message: message, meta: m))
    }

    // MARK: - RX/TX helpers

    private func formatLines(_ lines: [String]) -> String {
        lines
            .map { $0.replacingOccurrences(of: "\0", with: "") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
    }

    private func isLikelyNoData(_ lines: [String]) -> Bool {
        let joined = lines.joined(separator: " ").uppercased()
        return joined.contains("NO DATA") || joined.contains("NODATA") || joined == "?"
    }

    // MARK: - Init

    public init(connectionType: ConnectionType = .bluetooth) {
        self.connectionType = connectionType
#if targetEnvironment(simulator)
        elm327 = ELM327(comm: MOCKComm())
#else
        elm327 = OBDService.makeELM327(for: connectionType)
#endif
        elm327.obdDelegate = self

        t(.info, "OBDService init", category: "lifecycle", meta: [
            "initialConnectionType": connectionType.rawValue
        ])
    }

    private static func makeELM327(for type: ConnectionType) -> ELM327 {
        switch type {
        case .bluetooth:
            return ELM327(comm: BLEManager())
        case .wifi:
            return ELM327(comm: WifiManager())
        case .externalAccessory:
            return ELM327(comm: EAManager())
        case .demo:
            return ELM327(comm: MOCKComm())
        }
    }

    // MARK: - Connection Handling

    public func connectionStateChanged(state: ConnectionState) {
        DispatchQueue.main.async {
            let oldState = self.connectionState
            self.connectionState = state
            if oldState != state {
                OBDLogger.shared.logConnectionChange(from: oldState, to: state)
                self.t(.info, "connectionState changed", category: "connection", meta: [
                    "from": "\(oldState)",
                    "to": "\(state)"
                ])
            }
        }
    }

    /// Initiates the connection process to the OBD2 adapter and vehicle.
    public func startConnection(preferedProtocol: PROTOCOL? = nil, timeout: TimeInterval = 7) async throws -> OBDInfo {
        connectId = UUID().uuidString
        let startTime = CFAbsoluteTimeGetCurrent()

        t(.info, "startConnection begin", category: "connection", meta: [
            "timeout_s": String(format: "%.2f", timeout),
            "preferredProtocol": preferedProtocol.map { "\($0)" } ?? "nil"
        ])

        obdInfo("Starting connection with timeout: \(timeout)s", category: .connection)
        postOBDLogEvent(level: "info", category: .connection, message: "Starting connection with timeout: \(timeout)s")

        do {
            // 1) Connect to adapter
            t(.debug, "connectToAdapter begin", category: "connection")
            obdDebug("Connecting to adapter...", category: .connection)
            postOBDLogEvent(level: "debug", category: .connection, message: "Connecting to adapter...")

            try await elm327.connectToAdapter(timeout: timeout)

            t(.debug, "connectToAdapter success", category: "connection")

            // 2) Adapter init
            t(.debug, "adapterInitialization begin", category: "connection")
            obdDebug("Initializing adapter...", category: .connection)
            postOBDLogEvent(level: "debug", category: .connection, message: "Initializing adapter...")

            try await elm327.adapterInitialization()

            t(.debug, "adapterInitialization success", category: "connection")

            // 3) Vehicle setup
            t(.debug, "setupVehicle begin", category: "connection")
            obdDebug("Initializing vehicle connection...", category: .connection)
            postOBDLogEvent(level: "debug", category: .connection, message: "Initializing vehicle connection...")

            let vehicleInfo = try await initializeVehicle(preferedProtocol)

            let duration = CFAbsoluteTimeGetCurrent() - startTime
            OBDLogger.shared.logPerformance("Connection established", duration: duration, success: true)

            let vin = vehicleInfo.vin ?? "Unknown"
            t(.info, "startConnection success", category: "connection", meta: [
                "vin": vin,
                "durationMs": "\(Int(duration * 1000))"
            ])

            obdInfo("Successfully connected to vehicle: \(vin)", category: .connection)
            postOBDLogEvent(level: "info", category: .connection, message: "Successfully connected to vehicle: \(vin)")

            return vehicleInfo
        } catch {
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            OBDLogger.shared.logPerformance("Connection failed", duration: duration, success: false)

            let mapped = mapUnderlyingError(error)

            let cleanMessage = "Connection failed (\(mapped.code)): \(mapped.message)"
            t(.error, cleanMessage, category: "connection", meta: mapped.meta.merging([
                "durationMs": "\(Int(duration * 1000))"
            ]) { $1 })

            obdError(cleanMessage, category: .connection)
            postOBDLogEvent(level: "error", category: .connection, message: cleanMessage)

            throw OBDServiceError.adapterConnectionFailed(code: mapped.code, message: mapped.message, meta: mapped.meta)
        }
    }

    /// Initializes communication with the vehicle and retrieves vehicle information.
    func initializeVehicle(_ preferedProtocol: PROTOCOL?) async throws -> OBDInfo {
        try await elm327.setupVehicle(preferredProtocol: preferedProtocol)
    }

    /// Terminates the connection with the OBD2 adapter.
    public func stopConnection() {
        t(.info, "stopConnection", category: "connection")
        elm327.stopConnection()
    }

    /// Switches the active connection type.
    private func switchConnectionType(_ connectionType: ConnectionType) {
        t(.info, "switchConnectionType", category: "connection", meta: [
            "to": connectionType.rawValue
        ])
        stopConnection()
        initializeELM327()
    }

    private func initializeELM327() {
#if targetEnvironment(simulator)
        elm327 = ELM327(comm: MOCKComm())
#else
        elm327 = OBDService.makeELM327(for: connectionType)
#endif
        elm327.obdDelegate = self

        t(.info, "initializeELM327 complete", category: "lifecycle", meta: [
            "transport": transportLabel(for: connectionType)
        ])
    }

    private func transportLabel(for type: ConnectionType) -> String {
        switch type {
        case .bluetooth: return "ble"
        case .wifi: return "wifi"
        case .externalAccessory: return "ea"
        case .demo: return "demo"
        }
    }

    // MARK: - Request Handling

    var pidList: [OBDCommand] = []

    public func startContinuousUpdates(
        _ pids: [OBDCommand],
        unit: MeasurementUnit = .metric,
        interval: TimeInterval = 0.3
    ) -> AnyPublisher<[OBDCommand: MeasurementResult], Error> {

        t(.info, "startContinuousUpdates", category: "stream", meta: [
            "pidCount": "\(pids.count)",
            "interval_s": String(format: "%.2f", interval)
        ])

        return Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .flatMap(maxPublishers: .max(1)) { [weak self] _ -> AnyPublisher<[OBDCommand: MeasurementResult], Error> in
                Future { promise in
                    guard let self = self else {
                        promise(.failure(OBDServiceError.notConnectedToVehicle))
                        return
                    }
                    Task(priority: .userInitiated) {
                        do {
                            let results = try await self.requestPIDs(pids, unit: unit)
                            promise(.success(results))
                        } catch {
                            promise(.failure(error))
                        }
                    }
                }
                .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }

    public func addPID(_ pid: OBDCommand) { pidList.append(pid) }
    public func removePID(_ pid: OBDCommand) { pidList.removeAll { $0 == pid } }

    /// ✅ Batched Mode01 requests. Serialized behind requestLock.
    public func requestPIDs(_ commands: [OBDCommand], unit: MeasurementUnit) async throws -> [OBDCommand: MeasurementResult] {
        try await requestLock.withLock {
            let pidListString = commands.map { $0.properties.command }.joined(separator: ", ")

            t(.debug, "requestPIDs batch begin", category: "communication", meta: [
                "pids": pidListString
            ])

            let message = "01" + commands.compactMap { $0.properties.command.dropFirst(2) }.joined()
            let response = try await sendCommandInternal(message, retries: 10)

            guard let frame = try elm327.canProtocol?.parse(response).first else {
                let warn = "Batch parse produced no frames"
                t(.warning, warn, category: "communication", meta: ["pids": pidListString])
                return [:]
            }

            guard let data = frame.data else {
                let warn = "Parsed frame had nil data"
                t(.warning, warn, category: "communication", meta: ["pids": pidListString])
                return [:]
            }

            var batchedResponse = BatchedResponse(response: data, unit)

            let results: [OBDCommand: MeasurementResult] = commands.reduce(into: [:]) { result, command in
                if let measurement = batchedResponse.extractValue(command) {
                    result[command] = measurement
                } else {
                    t(.warning, "decode miss / NO DATA in batch", category: "communication", meta: [
                        "pid": command.properties.command
                    ])
                }
            }

            return results
        }
    }

    /// ✅ Normal command request. Serialized behind requestLock.
    public func sendCommand(_ command: OBDCommand) async throws -> Result<DecodeResult, DecodeError> {
        try await requestLock.withLock {
            do {
                let response = try await sendCommandInternal(command.properties.command, retries: 3)
                guard let responseData = try elm327.canProtocol?.parse(response).first?.data else {
                    t(.warning, "parse NO DATA", category: "communication", meta: ["pid": command.properties.command])
                    return .failure(.noData)
                }

                let decoded = command.properties.decode(data: responseData.dropFirst())
                if case .failure = decoded {
                    t(.warning, "decode failed", category: "communication", meta: ["pid": command.properties.command])
                }
                return decoded
            } catch {
                let mapped = mapUnderlyingError(error)
                t(.error, "sendCommand failed", category: "communication", meta: mapped.meta.merging([
                    "pid": command.properties.command,
                    "code": mapped.code,
                    "message": mapped.message
                ]) { $1 })
                throw OBDServiceError.commandFailed(command: command.properties.command, code: mapped.code, message: mapped.message, meta: mapped.meta)
            }
        }
    }

    /// ✅ Supported PIDs. Serialized too.
    public func getSupportedPIDs() async -> [OBDCommand] {
        (try? await requestLock.withLock {
            await elm327.getSupportedPIDs()
        }) ?? []
    }

    public func scanForTroubleCodes() async throws -> [ECUID: [TroubleCode]] {
        try await requestLock.withLock {
            do {
                return try await elm327.scanForTroubleCodes()
            } catch {
                let mapped = mapUnderlyingError(error)
                t(.error, "scanForTroubleCodes failed", category: "dtc", meta: mapped.meta.merging([
                    "code": mapped.code,
                    "message": mapped.message
                ]) { $1 })
                throw OBDServiceError.scanFailed(code: mapped.code, message: mapped.message, meta: mapped.meta)
            }
        }
    }

    public func clearTroubleCodes() async throws {
        try await requestLock.withLock {
            do {
                try await elm327.clearTroubleCodes()
            } catch {
                let mapped = mapUnderlyingError(error)
                t(.error, "clearTroubleCodes failed", category: "dtc", meta: mapped.meta.merging([
                    "code": mapped.code,
                    "message": mapped.message
                ]) { $1 })
                throw OBDServiceError.clearFailed(code: mapped.code, message: mapped.message, meta: mapped.meta)
            }
        }
    }

    public func getStatus() async throws -> Result<DecodeResult, DecodeError> {
        try await requestLock.withLock {
            try await elm327.getStatus()
        }
    }

    // MARK: - ✅ Vehicle Voltage (ATRV)

    public func requestVehicleVoltage(retries: Int = 2) async throws -> MeasurementResult {
        try await requestLock.withLock {
            guard connectionState != .disconnected else {
                throw OBDServiceError.notConnectedToVehicle
            }

            let lines = try await sendCommandInternal("ATRV", retries: retries)

            let joined = lines.joined(separator: " ")
            let cleaned = joined
                .replacingOccurrences(of: ">", with: "")
                .replacingOccurrences(of: "\0", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let noV = cleaned.replacingOccurrences(of: "V", with: "", options: [.caseInsensitive])
            let token = noV
                .components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
                .first(where: { !$0.isEmpty })

            guard let token, let value = Double(token) else {
                t(.error, "ATRV invalid response", category: "communication", meta: ["raw": joined])
                throw OBDServiceError.commandFailed(
                    command: "ATRV",
                    code: "elm.invalid_response",
                    message: "Invalid ATRV response",
                    meta: ["raw": joined]
                )
            }

            return MeasurementResult(value: value, unit: UnitElectricPotentialDifference.volts)
        }
    }

    /// Sends a raw command to the vehicle and returns the raw response.
    public func sendCommandInternal(_ message: String, retries: Int) async throws -> [String] {
        let rid = nextRequestID()
        let start = CFAbsoluteTimeGetCurrent()

        t(.debug, "TX", category: "wire", meta: [
            "requestId": "\(rid)",
            "command": message,
            "retries": "\(retries)"
        ])

        do {
            let lines = try await elm327.sendCommand(message, retries: retries)
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            let formatted = formatLines(lines)

            if isLikelyNoData(lines) {
                t(.warning, "RX NO DATA", category: "wire", meta: [
                    "requestId": "\(rid)",
                    "ms": "\(ms)",
                    "command": message,
                    "rx": formatted
                ])
            } else {
                t(.debug, "RX", category: "wire", meta: [
                    "requestId": "\(rid)",
                    "ms": "\(ms)",
                    "command": message,
                    "rx": formatted
                ])
            }

            return lines
        } catch {
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)

            // Keep NO DATA behavior
            if let ble = error as? BLEManagerError, ble == .noData {
                t(.warning, "ERR NO DATA", category: "wire", meta: [
                    "requestId": "\(rid)",
                    "ms": "\(ms)",
                    "command": message
                ])
                return []
            }

            let mapped = mapUnderlyingError(error)
            t(.error, "ERR", category: "wire", meta: mapped.meta.merging([
                "requestId": "\(rid)",
                "ms": "\(ms)",
                "command": message,
                "code": mapped.code,
                "message": mapped.message
            ]) { $1 })

            throw OBDServiceError.commandFailed(command: message, code: mapped.code, message: mapped.message, meta: mapped.meta)
        }
    }

    // MARK: - BLE-only helpers

    public func connectToPeripheral(peripheral: CBPeripheral) async throws {
        guard connectionType == .bluetooth else {
            t(.warning, "connectToPeripheral blocked (not BLE mode)", category: "ble", meta: [
                "selected": connectionType.rawValue
            ])
            throw OBDServiceError.operationNotSupportedForConnectionType(connectionType)
        }
        do {
            t(.info, "connectToPeripheral begin", category: "ble", meta: [
                "name": peripheral.name ?? "nil",
                "identifier": peripheral.identifier.uuidString
            ])
            try await elm327.connectToAdapter(timeout: 5, peripheral: peripheral)
            t(.info, "connectToPeripheral success", category: "ble")
        } catch {
            let mapped = mapUnderlyingError(error)
            t(.error, "connectToPeripheral failed", category: "ble", meta: mapped.meta.merging([
                "code": mapped.code,
                "message": mapped.message
            ]) { $1 })
            throw OBDServiceError.adapterConnectionFailed(code: mapped.code, message: mapped.message, meta: mapped.meta)
        }
    }

    public func scanForPeripherals() async throws {
        guard connectionType == .bluetooth else {
            t(.warning, "scanForPeripherals blocked (not BLE mode)", category: "ble", meta: [
                "selected": connectionType.rawValue
            ])
            throw OBDServiceError.operationNotSupportedForConnectionType(connectionType)
        }
        do {
            isScanning = true
            t(.info, "scanForPeripherals begin", category: "ble")
            try await elm327.scanForPeripherals()
            isScanning = false
            t(.info, "scanForPeripherals end", category: "ble")
        } catch {
            isScanning = false
            let mapped = mapUnderlyingError(error)
            t(.error, "scanForPeripherals failed", category: "ble", meta: mapped.meta.merging([
                "code": mapped.code,
                "message": mapped.message
            ]) { $1 })
            throw OBDServiceError.scanFailed(code: mapped.code, message: mapped.message, meta: mapped.meta)
        }
    }

        // MARK: - VIN



    public func requestVIN(retries: Int = 2) async throws -> String? {
        try await requestLock.withLock {
            guard connectionState != .disconnected else {
                throw OBDServiceError.notConnectedToVehicle
            }

            let lines = try await sendCommandInternal("0902", retries: retries)
            let vin = Self.parseVIN(from: lines)

            t(.info, "requestVIN result", category: "vin", meta: [
                "vin": vin ?? "nil",
                "rawLineCount": "\(lines.count)"
            ])

            return vin
        }
    }

    // MARK: - VIN

public func requestVIN(retries: Int = 2) async throws -> String? {
    try await requestLock.withLock {
        guard connectionState != .disconnected else {
            throw OBDServiceError.notConnectedToVehicle
        }

        var lastLines: [String] = []

        for attempt in 0...retries {
            let lines = try await sendCommandInternal("0902", retries: 0)
            lastLines = lines

            if let vin = Self.parseVIN(from: lines) {
                t(.info, "requestVIN success", category: "vin", meta: [
                    "attempt": "\(attempt + 1)",
                    "vin": vin,
                    "rawLineCount": "\(lines.count)"
                ])
                return vin
            }

            t(.warning, "requestVIN parse failed", category: "vin", meta: [
                "attempt": "\(attempt + 1)",
                "rawLineCount": "\(lines.count)",
                "raw": lines.joined(separator: " | ")
            ])

            if attempt < retries {
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
        }

        t(.info, "requestVIN result", category: "vin", meta: [
            "vin": "nil",
            "rawLineCount": "\(lastLines.count)",
            "raw": lastLines.joined(separator: " | ")
        ])

        return nil
    }
}

private static func parseVIN(from lines: [String]) -> String? {
    let cleanedLines = lines
        .map { $0.replacingOccurrences(of: "\0", with: "") }
        .map { $0.replacingOccurrences(of: ">", with: "") }
        .map { $0.replacingOccurrences(of: ":", with: " ") }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    var collected: [UInt8] = []

    for line in cleanedLines {
        let tokens = line
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)

        let bytes = tokens.compactMap { UInt8($0, radix: 16) }
        guard !bytes.isEmpty else { continue }

        guard let start = bytes.firstIndex(of: 0x49),
              start + 1 < bytes.count,
              bytes[start + 1] == 0x02 else {
            continue
        }

        // Common VIN response format:
        // 49 02 01 xx xx xx ...
        // Skip 49 02 and the frame index byte.
        let payloadStart = start + 3
        guard payloadStart < bytes.count else { continue }

        collected.append(contentsOf: bytes[payloadStart...])
    }

    guard !collected.isEmpty else { return nil }

    // Build a clean VIN-like string from printable alphanumerics only.
    let vinChars: [Character] = collected.compactMap { byte in
        guard let scalar = UnicodeScalar(Int(byte)) else { return nil }
        let ch = Character(scalar)
        return ch.isLetter || ch.isNumber ? Character(String(ch).uppercased()) : nil
    }

    guard !vinChars.isEmpty else { return nil }

    var vin = String(vinChars)

    // Some adapters duplicate or over-return data; trim to first 17 chars.
    if vin.count > 17 {
        vin = String(vin.prefix(17))
    }

    guard vin.count == 17 else { return nil }
    guard vin != "UNKNOWN" else { return nil }

    // Real VINs do not use I, O, or Q.
    guard !vin.contains("I"),
          !vin.contains("O"),
          !vin.contains("Q") else {
        return nil
    }

    return vin
}

// MARK: - Error mapping (NO SwiftOBD2 leakage)

private extension OBDService {
    struct MappedError {
        let code: String
        let message: String
        let meta: [String: String]
    }

    func mapUnderlyingError(_ error: Error) -> MappedError {
        let ns = error as NSError

        var meta: [String: String] = [
            "nsDomain": ns.domain,
            "nsCode": "\(ns.code)",
            "nsDescription": ns.localizedDescription
        ]

        // Keep type info in meta (OK), but DO NOT put it in user-facing message.
        meta["type"] = String(reflecting: type(of: error))

        // Special-case: "error 0"
        if ns.code == 0 {
            return MappedError(
                code: "transport.unknown_0",
                message: "Transport failed with unknown error (code 0).",
                meta: meta
            )
        }

        if let ble = error as? BLEManagerError {
            meta["bleCase"] = String(describing: ble)
            switch ble {
            case .noData:
                return MappedError(code: "ble.no_data", message: "No data returned for request.", meta: meta)
            case .timeout:
                return MappedError(code: "ble.timeout", message: "Timed out waiting for adapter response.", meta: meta)
            case .peripheralNotFound:
                return MappedError(code: "ble.peripheral_not_found", message: "Adapter not found.", meta: meta)
            case .missingPeripheralOrCharacteristic:
                return MappedError(code: "ble.missing_characteristic", message: "Missing peripheral or characteristic.", meta: meta)
            default:
                return MappedError(code: "ble.error", message: "Bluetooth transport error.", meta: meta)
            }
        }

        if let elm = error as? ELM327Error {
            meta["elmCase"] = String(describing: elm)
            return MappedError(code: "elm.error", message: "Adapter returned an invalid/failed response.", meta: meta)
        }

        return MappedError(code: "unknown", message: ns.localizedDescription, meta: meta)
    }
}

// MARK: - Errors (stable code/message/meta)

public enum OBDServiceError: Error {
    case noAdapterFound
    case notConnectedToVehicle

    case adapterConnectionFailed(code: String, message: String, meta: [String: String])
    case scanFailed(code: String, message: String, meta: [String: String])
    case clearFailed(code: String, message: String, meta: [String: String])
    case commandFailed(command: String, code: String, message: String, meta: [String: String])

    case operationNotSupportedForConnectionType(ConnectionType)
}

extension OBDServiceError: LocalizedError {

    public var errorDescription: String? {
        switch self {

        case .noAdapterFound:
            return "No OBD adapter was found."

        case .notConnectedToVehicle:
            return "Not connected to the vehicle."

        case .adapterConnectionFailed(_, let message, _):
            return message

        case .scanFailed(_, let message, _):
            return message

        case .clearFailed(_, let message, _):
            return message

        case .commandFailed(_, _, let message, _):
            return message

        case .operationNotSupportedForConnectionType(let type):
            return "Operation not supported when using \(type.rawValue)."
        }
    }
}

// MARK: - MeasurementResult

public struct MeasurementResult: Equatable {
    public var value: Double
    public let unit: Unit

    public init(value: Double, unit: Unit) {
        self.value = value
        self.unit = unit
    }
}

public extension MeasurementResult {
    static func mock(_ value: Double = 125, _ suffix: String = "km/h") -> MeasurementResult {
        .init(value: value, unit: .init(symbol: suffix))
    }
}

// MARK: - VIN Helper

public func getVINInfo(vin: String) async throws -> VINResults {
    let endpoint = "https://vpic.nhtsa.dot.gov/api/vehicles/decodevinvalues/\(vin)?format=json"

    guard let url = URL(string: endpoint) else {
        throw URLError(.badURL)
    }

    let (data, response) = try await URLSession.shared.data(from: url)

    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw URLError(.badServerResponse)
    }

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(VINResults.self, from: data)
    return decoded
}

public struct VINResults: Codable {
    public let Results: [VINInfo]
}

public struct VINInfo: Codable, Hashable {
    public let Make: String
    public let Model: String
    public let ModelYear: String
    public let EngineCylinders: String
}
