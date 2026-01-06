//
//  obd2service.swift
//  SwiftOBD2
//
//  Drop-in replacement: adds BLE auto-scan + auto-connect on iOS (no Settings pairing required)
//  Works with Vgate iCar / IOS-Vlink style adapters.
//
//  Notes:
//  - Keeps public API the same.
//  - Uses BLEPeripheralScanner.supportedServices to find compatible adapters.
//  - Updates isScanning + connectedPeripheral for UI/state.
//

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

public final class ConfigurationService {
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

/// A class that provides an interface to the ELM327 OBD2 adapter and the vehicle.
///
/// Key responsibilities:
/// - Establishing a connection to the adapter and the vehicle.
/// - Sending and receiving OBD2 commands.
/// - Providing information about the vehicle.
/// - Managing the connection state.
public final class OBDService: ObservableObject, OBDServiceDelegate {

    // MARK: Published state
    @Published public private(set) var connectionState: ConnectionState = .disconnected
    @Published public private(set) var isScanning: Bool = false
    @Published public private(set) var connectedPeripheral: CBPeripheral?

    @Published public var connectionType: ConnectionType {
        didSet {
            switchConnectionType(connectionType)
            ConfigurationService.shared.connectionType = connectionType
        }
    }

    // MARK: Internal
    private var elm327: ELM327
    private var bleManager: BLEManager?
    private var wifiManager: WifiManager?
    private var cancellables = Set<AnyCancellable>()

    // MARK: Init
    public init(connectionType: ConnectionType = .bluetooth) {
        self.connectionType = connectionType

        #if targetEnvironment(simulator)
        self.bleManager = nil
        self.wifiManager = nil
        self.elm327 = ELM327(comm: MOCKComm())
        #else
        switch connectionType {
        case .bluetooth:
            let mgr = BLEManager()
            self.bleManager = mgr
            self.wifiManager = nil
            self.elm327 = ELM327(comm: mgr)

        case .wifi:
            let mgr = WifiManager()
            self.wifiManager = mgr
            self.bleManager = nil
            self.elm327 = ELM327(comm: mgr)

        case .demo:
            self.bleManager = nil
            self.wifiManager = nil
            self.elm327 = ELM327(comm: MOCKComm())
        }
        #endif

        self.elm327.obdDelegate = self
    }

    // MARK: OBDServiceDelegate
    public func connectionStateChanged(state: ConnectionState) {
        DispatchQueue.main.async {
            let oldState = self.connectionState
            self.connectionState = state
            if oldState != state {
                OBDLogger.shared.logConnectionChange(from: oldState, to: state)
            }
        }
    }

    // MARK: Connection

    /// Initiates the connection process to the OBD2 adapter and vehicle.
    ///
    /// - Parameters:
    ///   - preferedProtocol: Optional preferred OBD2 protocol.
    ///   - timeout: BLE scan/connect timeout.
    /// - Returns: Vehicle info (`OBDInfo`).
    public func startConnection(preferedProtocol: PROTOCOL? = nil,
                                timeout: TimeInterval = 7) async throws -> OBDInfo {

        let startTime = CFAbsoluteTimeGetCurrent()
        obdInfo("Starting connection (type=\(connectionType.rawValue)) timeout=\(timeout)s", category: .connection)

        do {
            // ✅ iOS BLE adapters typically do NOT show up in Settings > Bluetooth.
            // We scan + connect inside the app.
            if connectionType == .bluetooth {
                try await connectBLEAutomatically(timeout: timeout)
            } else {
                // For Wi-Fi/demo, rely on existing comm behavior
                obdDebug("Connecting to adapter...", category: .connection)
                try await elm327.connectToAdapter(timeout: timeout)
            }

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

    /// BLE auto scan + connect (no Settings pairing).
    private func connectBLEAutomatically(timeout: TimeInterval) async throws {
        guard let bleManager else { throw OBDServiceError.noAdapterFound }

        isScanning = true
        defer { isScanning = false }

        connectedPeripheral = nil

        obdDebug("Scanning for BLE OBD adapters...", category: .connection)

        // Scan for peripherals advertising known OBD services
        try await bleManager.scanForPeripherals(services: BLEPeripheralScanner.supportedServices)

        // Wait for first compatible peripheral found
        let peripheral = try await bleManager.waitForFirstPeripheral(timeout: timeout)
        connectedPeripheral = peripheral

        obdInfo("Found BLE adapter: \(peripheral.name ?? "Unknown")", category: .connection)

        // Connect directly (no iOS pairing)
        try await elm327.connectToAdapter(timeout: timeout, peripheral: peripheral)
    }

    /// Initializes vehicle comms + returns info.
    func initializeVehicle(_ preferedProtocol: PROTOCOL?) async throws -> OBDInfo {
        try await elm327.setupVehicle(preferredProtocol: preferedProtocol)
    }

    /// Terminates the connection.
    public func stopConnection() {
        elm327.stopConnection()
    }

    private func switchConnectionType(_ connectionType: ConnectionType) {
        stopConnection()
        initializeELM327()
    }

    private func initializeELM327() {
        #if targetEnvironment(simulator)
        self.bleManager = nil
        self.wifiManager = nil
        self.elm327 = ELM327(comm: MOCKComm())
        #else
        switch connectionType {
        case .bluetooth:
            let mgr = BLEManager()
            self.bleManager = mgr
            self.wifiManager = nil
            self.elm327 = ELM327(comm: mgr)

        case .wifi:
            let mgr = WifiManager()
            self.wifiManager = mgr
            self.bleManager = nil
            self.elm327 = ELM327(comm: mgr)

        case .demo:
            self.bleManager = nil
            self.wifiManager = nil
            self.elm327 = ELM327(comm: MOCKComm())
        }
        #endif

        self.elm327.obdDelegate = self
    }

    // MARK: - Request Handling

    var pidList: [OBDCommand] = []

    /// Starts continuous updates for the given PIDs.
    public func startContinuousUpdates(_ pids: [OBDCommand],
                                       unit: MeasurementUnit = .metric,
                                       interval: TimeInterval = 0.3) -> AnyPublisher<[OBDCommand: MeasurementResult], Error> {
        Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .flatMap { [weak self] _ -> Future<[OBDCommand: MeasurementResult], Error> in
                Future { promise in
                    guard let self else {
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

    /// Adds a PID to the list.
    public func addPID(_ pid: OBDCommand) {
        pidList.append(pid)
    }

    /// Removes a PID from the list.
    public func removePID(_ pid: OBDCommand) {
        pidList.removeAll { $0 == pid }
    }

    /// Requests a batch of PIDs.
    public func requestPIDs(_ commands: [OBDCommand], unit: MeasurementUnit) async throws -> [OBDCommand: MeasurementResult] {
        let response = try await sendCommandInternal(
            "01" + commands.compactMap { $0.properties.command.dropFirst(2) }.joined(),
            retries: 10
        )

        guard let responseData = try elm327.canProtocol?.parse(response).first?.data else { return [:] }

        var batchedResponse = BatchedResponse(response: responseData, unit)

        let results: [OBDCommand: MeasurementResult] = commands.reduce(into: [:]) { result, command in
            let measurement = batchedResponse.extractValue(command)
            result[command] = measurement
        }

        return results
    }

    /// Sends a command and decodes it.
    public func sendCommand(_ command: OBDCommand) async throws -> Result<DecodeResult, DecodeError> {
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

    /// Returns supported PIDs (cached by ELM setup logic).
    public func getSupportedPIDs() async -> [OBDCommand] {
        await elm327.getSupportedPIDs()
    }

    /// Scans for trouble codes.
    public func scanForTroubleCodes() async throws -> [ECUID: [TroubleCode]] {
        do {
            return try await elm327.scanForTroubleCodes()
        } catch {
            throw OBDServiceError.scanFailed(underlyingError: error)
        }
    }

    /// Clears trouble codes.
    public func clearTroubleCodes() async throws {
        do {
            try await elm327.clearTroubleCodes()
        } catch {
            throw OBDServiceError.clearFailed(underlyingError: error)
        }
    }

    /// Vehicle status.
    public func getStatus() async throws -> Result<DecodeResult, DecodeError> {
        try await elm327.getStatus()
    }

    /// Sends a raw command.
    public func sendCommandInternal(_ message: String, retries: Int) async throws -> [String] {
        do {
            return try await elm327.sendCommand(message, retries: retries)
        } catch {
            throw OBDServiceError.commandFailed(command: message, error: error)
        }
    }

    /// Manual connect to a specific peripheral (if your UI lets user pick).
    public func connectToPeripheral(peripheral: CBPeripheral) async throws {
        do {
            try await elm327.connectToAdapter(timeout: 5, peripheral: peripheral)
        } catch {
            throw OBDServiceError.adapterConnectionFailed(underlyingError: error)
        }
    }

    /// Manual scan (kept for compatibility).
    public func scanForPeripherals() async throws {
        do {
            self.isScanning = true
            defer { self.isScanning = false }
            try await elm327.scanForPeripherals()
        } catch {
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

// MARK: - VIN Decode Helpers

public func getVINInfo(vin: String) async throws -> VINResults {
    let endpoint = "https://vpic.nhtsa.dot.gov/api/vehicles/decodevinvalues/\(vin)?format=json"
    guard let url = URL(string: endpoint) else { throw URLError(.badURL) }

    let (data, response) = try await URLSession.shared.data(from: url)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }

    let decoder = JSONDecoder()
    return try decoder.decode(VINResults.self, from: data)
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
