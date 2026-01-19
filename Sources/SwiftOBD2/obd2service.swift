import Combine
import CoreBluetooth
import Foundation

public enum ConnectionType: String, CaseIterable {
    case bluetooth = "Bluetooth"
    case wifi = "Wi-Fi"
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
            let rawValue = UserDefaults.standard.string(forKey: "connectionType") ?? "Bluetooth"
            return ConnectionType(rawValue: rawValue) ?? .bluetooth
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "connectionType")
        }
    }
}

// MARK: - ✅ Single request gate (prevents interleaved BLE responses)

public actor OBDRequestLock {
    public init() {}
    public func withLock<T>(_ op: () async throws -> T) async throws -> T {
        try await op()
    }
}

/// A class that provides an interface to the ELM327 OBD2 adapter and the vehicle.
///
/// - Key Responsibilities:
///   - Establishing a connection to the adapter and the vehicle.
///   - Sending and receiving OBD2 commands.
///   - Providing information about the vehicle.
///   - Managing the connection state.
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
    /// This is the #1 fix for: wrong PID readings, negative coolant after errors, “error 3” cascades on BLE ELM clones.
    private let requestLock = OBDRequestLock()

    /// Initializes the OBDService object.
    ///
    /// - Parameter connectionType: The desired connection type (default is Bluetooth).
    ///
    public init(connectionType: ConnectionType = .bluetooth) {
        self.connectionType = connectionType
#if targetEnvironment(simulator)
        elm327 = ELM327(comm: MOCKComm())
#else
        switch connectionType {
        case .bluetooth:
            let bleManager = BLEManager()
            elm327 = ELM327(comm: bleManager)
        case .wifi:
            elm327 = ELM327(comm: WifiManager())
        case .demo:
            elm327 = ELM327(comm: MOCKComm())
        }
#endif
        elm327.obdDelegate = self
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
    ///
    /// - Parameter preferedProtocol: The optional OBD2 protocol to use (if supported).
    /// - Returns: Information about the connected vehicle (`OBDInfo`).
    /// - Throws: Errors that might occur during the connection process.
    public func startConnection(preferedProtocol: PROTOCOL? = nil, timeout: TimeInterval = 7) async throws -> OBDInfo {
        let startTime = CFAbsoluteTimeGetCurrent()
        obdInfo("Starting connection with timeout: \(timeout)s", category: .connection)

        do {
            obdDebug("Connecting to adapter...", category: .connection)
            try await elm327.connectToAdapter(timeout: timeout)

            obdDebug("Initializing adapter...", category: .connection)
            try await elm327.adapterInitialization()

            obdDebug("Initializing vehicle connection...", category: .connection)
            let vehicleInfo = try await initializeVehicle(preferedProtocol)

            let duration = CFAbsoluteTimeGetCurrent() - startTime
            OBDLogger.shared.logPerformance("Connection established", duration: duration, success: true)
            obdInfo("Successfully connected to vehicle: \(vehicleInfo.vin ?? "Unknown")", category: .connection)

            return vehicleInfo
        } catch {
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            OBDLogger.shared.logPerformance("Connection failed", duration: duration, success: false)
            obdError("Connection failed: \(error.localizedDescription)", category: .connection)
            throw OBDServiceError.adapterConnectionFailed(underlyingError: error)
        }
    }

    /// Initializes communication with the vehicle and retrieves vehicle information.
    func initializeVehicle(_ preferedProtocol: PROTOCOL?) async throws -> OBDInfo {
        let obd2info = try await elm327.setupVehicle(preferredProtocol: preferedProtocol)
        return obd2info
    }

    /// Terminates the connection with the OBD2 adapter.
    public func stopConnection() {
        elm327.stopConnection()
    }

    /// Switches the active connection type (between Bluetooth and Wi-Fi).
    private func switchConnectionType(_ connectionType: ConnectionType) {
        stopConnection()
        initializeELM327()
    }

    private func initializeELM327() {
        switch connectionType {
        case .bluetooth:
            let bleManager = BLEManager()
            elm327 = ELM327(comm: bleManager)
        case .wifi:
            elm327 = ELM327(comm: WifiManager())
        case .demo:
            elm327 = ELM327(comm: MOCKComm())
        }
        elm327.obdDelegate = self
    }

    // MARK: - Request Handling

    var pidList: [OBDCommand] = []

    public func startContinuousUpdates(
        _ pids: [OBDCommand],
        unit: MeasurementUnit = .metric,
        interval: TimeInterval = 0.3
    ) -> AnyPublisher<[OBDCommand: MeasurementResult], Error> {
        Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .flatMap { [weak self] _ -> Future<[OBDCommand: MeasurementResult], Error> in
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
            }
            .eraseToAnyPublisher()
    }

    public func addPID(_ pid: OBDCommand) {
        pidList.append(pid)
    }

    public func removePID(_ pid: OBDCommand) {
        pidList.removeAll { $0 == pid }
    }

    /// ✅ Batched Mode01 requests. Now serialized behind requestLock.
    public func requestPIDs(_ commands: [OBDCommand], unit: MeasurementUnit) async throws -> [OBDCommand: MeasurementResult] {
        try await requestLock.withLock {
            let message = "01" + commands.compactMap { $0.properties.command.dropFirst(2) }.joined()
            let response = try await sendCommandInternal(message, retries: 10)

            guard let responseData = try elm327.canProtocol?.parse(response).first?.data else { return [:] }

            var batchedResponse = BatchedResponse(response: responseData, unit)

            let results: [OBDCommand: MeasurementResult] = commands.reduce(into: [:]) { result, command in
                let measurement = batchedResponse.extractValue(command)
                result[command] = measurement
            }

            return results
        }
    }

    /// ✅ Normal command request. Now serialized behind requestLock.
    public func sendCommand(_ command: OBDCommand) async throws -> Result<DecodeResult, DecodeError> {
        try await requestLock.withLock {
            do {
                let response = try await sendCommandInternal(command.properties.command, retries: 3)
                guard let responseData = try elm327.canProtocol?.parse(response).first?.data else {
                    return .failure(.noData)
                }
                return command.properties.decode(data: responseData.dropFirst())
            } catch {
                throw OBDServiceError.commandFailed(command: command.properties.command, error: error)
            }
        }
    }

    /// ✅ Supported PIDs. Recommended to serialize too.
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

    /// Reads battery/vehicle voltage from the adapter (ATRV).
    /// Works as soon as you're connected to the adapter; vehicle connection helps but isn't strictly required.
    public func requestVehicleVoltage(retries: Int = 2) async throws -> MeasurementResult {
        try await requestLock.withLock {
            guard connectionState != .disconnected else {
                throw OBDServiceError.notConnectedToVehicle
            }

            let lines = try await sendCommandInternal("ATRV", retries: retries)

            // Common: ["12.4V"] or ["12.4 V"] or includes prompt chars
            let joined = lines.joined(separator: " ")
            let cleaned = joined
                .replacingOccurrences(of: ">", with: "")
                .replacingOccurrences(of: "\0", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Remove "V" / "v"
            let noV = cleaned.replacingOccurrences(of: "V", with: "", options: [.caseInsensitive])

            // Grab first numeric token (handles weird extra text)
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
        do {
            return try await elm327.sendCommand(message, retries: retries)
        } catch {
            throw OBDServiceError.commandFailed(command: message, error: error)
        }
    }

    public func connectToPeripheral(peripheral: CBPeripheral) async throws {
        do {
            try await elm327.connectToAdapter(timeout: 5, peripheral: peripheral)
        } catch {
            throw OBDServiceError.adapterConnectionFailed(underlyingError: error)
        }
    }

    public func scanForPeripherals() async throws {
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
