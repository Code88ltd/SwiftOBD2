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
    static var shared = ConfigurationService()
    var connectionType: ConnectionType {
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

/// A class that provides an interface to the ELM327 OBD2 adapter and the vehicle.
public class OBDService: ObservableObject, OBDServiceDelegate {

    @Published public private(set) var connectionState: ConnectionState = .disconnected
    @Published public private(set) var isScanning: Bool = false
    @Published public private(set) var connectedPeripheral: CBPeripheral?

    @Published public var connectionType: ConnectionType {
        didSet {
            switchConnectionType(connectionType)
            ConfigurationService.shared.connectionType = connectionType
        }
    }

    /// The internal ELM327 object responsible for direct adapter interaction.
    private var elm327: ELM327

    private var cancellables = Set<AnyCancellable>()

    /// ✅ One lock for ALL adapter/ECU I/O.
    private let requestLock = OBDRequestLock()

    // MARK: - ✅ Logging helpers (TX/RX)

    private var requestCounter: UInt64 = 0
    private func nextRequestID() -> UInt64 {
        requestCounter &+= 1
        return requestCounter
    }

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
            }
        }
    }

    /// Initiates the connection process to the OBD2 adapter and vehicle.
    public func startConnection(preferedProtocol: PROTOCOL? = nil, timeout: TimeInterval = 7) async throws -> OBDInfo {
        let startTime = CFAbsoluteTimeGetCurrent()
        obdInfo("Starting connection with timeout: \(timeout)s", category: .connection)
        postOBDLogEvent(level: "info", category: .connection, message: "Starting connection with timeout: \(timeout)s")

        do {
            obdDebug("Connecting to adapter...", category: .connection)
            postOBDLogEvent(level: "debug", category: .connection, message: "Connecting to adapter...")
            try await elm327.connectToAdapter(timeout: timeout)

            obdDebug("Initializing adapter...", category: .connection)
            postOBDLogEvent(level: "debug", category: .connection, message: "Initializing adapter...")
            try await elm327.adapterInitialization()

            obdDebug("Initializing vehicle connection...", category: .connection)
            postOBDLogEvent(level: "debug", category: .connection, message: "Initializing vehicle connection...")
            let vehicleInfo = try await initializeVehicle(preferedProtocol)

            let duration = CFAbsoluteTimeGetCurrent() - startTime
            OBDLogger.shared.logPerformance("Connection established", duration: duration, success: true)
            obdInfo("Successfully connected to vehicle: \(vehicleInfo.vin ?? "Unknown")", category: .connection)
            postOBDLogEvent(level: "info", category: .connection, message: "Successfully connected to vehicle: \(vehicleInfo.vin ?? "Unknown")")

            return vehicleInfo
        } catch {
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            OBDLogger.shared.logPerformance("Connection failed", duration: duration, success: false)
            obdError("Connection failed: \(error.localizedDescription)", category: .connection)
            postOBDLogEvent(level: "error", category: .connection, message: "Connection failed: \(error.localizedDescription)")
            throw OBDServiceError.adapterConnectionFailed(underlyingError: error)
        }
    }

    /// Initializes communication with the vehicle and retrieves vehicle information.
    func initializeVehicle(_ preferedProtocol: PROTOCOL?) async throws -> OBDInfo {
        try await elm327.setupVehicle(preferredProtocol: preferedProtocol)
    }

    /// Terminates the connection with the OBD2 adapter.
    public func stopConnection() {
        elm327.stopConnection()
    }

    /// Switches the active connection type.
    private func switchConnectionType(_ connectionType: ConnectionType) {
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
    }

    // MARK: - Request Handling

    var pidList: [OBDCommand] = []

    public func startContinuousUpdates(
        _ pids: [OBDCommand],
        unit: MeasurementUnit = .metric,
        interval: TimeInterval = 0.3
    ) -> AnyPublisher<[OBDCommand: MeasurementResult], Error> {

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
            let batchMsg = "Batch request: [\(pidListString)]"
            obdDebug(batchMsg, category: .communication)
            postOBDLogEvent(level: "debug", category: .communication, message: batchMsg)

            let message = "01" + commands.compactMap { $0.properties.command.dropFirst(2) }.joined()
            let response = try await sendCommandInternal(message, retries: 10)

            guard let frame = try elm327.canProtocol?.parse(response).first else {
                let warn = "Batch parse produced no frames for [\(pidListString)]"
                obdWarning(warn, category: .communication)
                postOBDLogEvent(level: "warning", category: .communication, message: warn)
                return [:]
            }

            guard let data = frame.data else {
                let warn = "Parsed frame had nil data for [\(pidListString)] :: \(frame)"
                obdWarning(warn, category: .communication)
                postOBDLogEvent(level: "warning", category: .communication, message: warn)
                return [:]
            }

            var batchedResponse = BatchedResponse(response: data, unit)

            let results: [OBDCommand: MeasurementResult] = commands.reduce(into: [:]) { result, command in
                if let measurement = batchedResponse.extractValue(command) {
                    result[command] = measurement
                } else {
                    let warn = "NO DATA / decode miss in batch for PID \(command.properties.command)"
                    obdWarning(warn, category: .communication)
                    postOBDLogEvent(level: "warning", category: .communication, message: warn)
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
                    let warn = "Parse NO DATA for \(command.properties.command)"
                    obdWarning(warn, category: .communication)
                    postOBDLogEvent(level: "warning", category: .communication, message: warn)
                    return .failure(.noData)
                }

                let decoded = command.properties.decode(data: responseData.dropFirst())
                if case .failure(let err) = decoded {
                    let warn = "Decode failed for \(command.properties.command): \(err)"
                    obdWarning(warn, category: .communication)
                    postOBDLogEvent(level: "warning", category: .communication, message: warn)
                }
                return decoded
            } catch {
                throw OBDServiceError.commandFailed(command: command.properties.command, error: error)
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
                throw OBDServiceError.scanFailed(underlyingError: error)
            }
        }
    }

    public func clearTroubleCodes() async throws {
        try await requestLock.withLock {
            do {
                try await elm327.clearTroubleCodes()
            } catch {
                throw OBDServiceError.clearFailed(underlyingError: error)
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
                throw OBDServiceError.commandFailed(command: "ATRV", error: ELM327Error.invalidResponse(message: joined))
            }

            return MeasurementResult(value: value, unit: UnitElectricPotentialDifference.volts)
        }
    }

    /// Sends a raw command to the vehicle and returns the raw response.
    /// NOTE: This is called inside requestLock wrappers above.
    public func sendCommandInternal(_ message: String, retries: Int) async throws -> [String] {
        let id = nextRequestID()
        let start = CFAbsoluteTimeGetCurrent()

        let tx = "TX [#\(id)] → \(message) (retries=\(retries))"
        obdDebug(tx, category: .communication)
        postOBDLogEvent(level: "debug", category: .communication, message: tx)

        do {
            let lines = try await elm327.sendCommand(message, retries: retries)
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            let formatted = formatLines(lines)

            if isLikelyNoData(lines) {
                let msg = "RX [#\(id)] ← NO DATA (\(ms)ms) :: \(formatted)"
                obdWarning(msg, category: .communication)
                postOBDLogEvent(level: "warning", category: .communication, message: msg)
            } else {
                let msg = "RX [#\(id)] ← (\(ms)ms) :: \(formatted)"
                obdDebug(msg, category: .communication)
                postOBDLogEvent(level: "debug", category: .communication, message: msg)
            }

            return lines
        } catch {
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)

            // Treat "NO DATA" as non-fatal for unsupported PIDs
            if let ble = error as? BLEManagerError {
                switch ble {
                case .noData:
                    let msg = "ERR [#\(id)] \(message) (\(ms)ms) :: NO DATA"
                    obdWarning(msg, category: .communication)
                    postOBDLogEvent(level: "warning", category: .communication, message: msg)
                    return []
                default:
                    break
                }
            }

            let msg = "ERR [#\(id)] \(message) (\(ms)ms) :: \(error.localizedDescription)"
            obdError(msg, category: .communication)
            postOBDLogEvent(level: "error", category: .communication, message: msg)
            throw OBDServiceError.commandFailed(command: message, error: error)
        }
    }

    // MARK: - BLE-only helpers

    public func connectToPeripheral(peripheral: CBPeripheral) async throws {
        guard connectionType == .bluetooth else {
            throw OBDServiceError.operationNotSupportedForConnectionType(connectionType)
        }
        do {
            try await elm327.connectToAdapter(timeout: 5, peripheral: peripheral)
        } catch {
            throw OBDServiceError.adapterConnectionFailed(underlyingError: error)
        }
    }

    public func scanForPeripherals() async throws {
        guard connectionType == .bluetooth else {
            throw OBDServiceError.operationNotSupportedForConnectionType(connectionType)
        }
        do {
            self.isScanning = true
            try await elm327.scanForPeripherals()
            self.isScanning = false
        } catch {
            self.isScanning = false
            throw OBDServiceError.scanFailed(underlyingError: error)
        }
    }
}

// MARK: - Errors

public enum OBDServiceError: Error {
    case noAdapterFound
    case notConnectedToVehicle
    case adapterConnectionFailed(underlyingError: Error)
    case scanFailed(underlyingError: Error)
    case clearFailed(underlyingError: Error)
    case commandFailed(command: String, error: Error)
    case operationNotSupportedForConnectionType(ConnectionType)
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

// MARK: - VIN Helper (unchanged)

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
