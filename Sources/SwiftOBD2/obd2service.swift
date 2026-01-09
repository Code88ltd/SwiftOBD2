//
//  obd2service.swift
//  SwiftOBD2
//
//  Drop-in replacement: BLE auto-connect on iOS (no Settings pairing required)
//  Uses BLEManager.connectAsync(), which waits for bluetooth poweredOn, scans, connects, and waits for characteristics.
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
    fileprivate var elm327: ELM327
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

    public func startConnection(preferedProtocol: PROTOCOL? = nil,
                                timeout: TimeInterval = 7) async throws -> OBDInfo {

        let startTime = CFAbsoluteTimeGetCurrent()
        obdInfo("Starting connection (type=\(connectionType.rawValue)) timeout=\(timeout)s", category: .connection)

        do {
            switch connectionType {
            case .bluetooth:
                guard let bleManager else { throw OBDServiceError.noAdapterFound }

                isScanning = true
                defer { isScanning = false }

                try await bleManager.connectAsync(timeout: timeout)

            case .wifi, .demo:
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

    func initializeVehicle(_ preferedProtocol: PROTOCOL?) async throws -> OBDInfo {
        try await elm327.setupVehicle(preferredProtocol: preferedProtocol)
    }

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

    public func addPID(_ pid: OBDCommand) { pidList.append(pid) }

    public func removePID(_ pid: OBDCommand) {
        pidList.removeAll { $0 == pid }
    }

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

    public func getSupportedPIDs() async -> [OBDCommand] {
        await elm327.getSupportedPIDs()
    }

    public func scanForTroubleCodes() async throws -> [ECUID: [TroubleCode]] {
        do {
            return try await elm327.scanForTroubleCodes()
        } catch {
            throw OBDServiceError.scanFailed(underlyingError: error)
        }
    }

    public func clearTroubleCodes() async throws {
        do {
            try await elm327.clearTroubleCodes()
        } catch {
            throw OBDServiceError.clearFailed(underlyingError: error)
        }
    }

    public func getStatus() async throws -> Result<DecodeResult, DecodeError> {
        try await elm327.getStatus()
    }

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
            defer { self.isScanning = false }
            try await elm327.scanForPeripherals()
        } catch {
            throw OBDServiceError.scanFailed(underlyingError: error)
        }
    }
}

// MARK: - NEW: Mode 22 / Mode 21 support

public extension OBDService {

    /// Generic raw PID request (e.g. "22F442", "2146").
    /// Returns parsed payload bytes from the ECU response.
    func requestRawPID(_ command: String, retries: Int = 10) async throws -> [UInt8] {
        let cleaned = command
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        let response = try await sendCommandInternal(cleaned, retries: retries)

        guard let responseData = try elm327.canProtocol?.parse(response).first?.data else {
            throw OBDServicePIDError.invalidResponse("No parsed response data")
        }

        // Support Data or [UInt8] depending on your protocol parser.
        if let d = responseData as? Data {
            return [UInt8](d)
        }
        if let arr = responseData as? [UInt8] {
            return arr
        }

        throw OBDServicePIDError.invalidResponse("Unsupported response data type: \(type(of: responseData))")
    }

    /// Mode 22 request (extended diagnostics).
    /// Example PID: "F442" -> sends "22F442" -> expects "62F442..."
    func requestMode22(_ pid: String, retries: Int = 10) async throws -> [UInt8] {
        let cleaned = pid.trimmed.uppercased()
        guard cleaned.count == 4, let pidBytes = hexToBytes(cleaned), pidBytes.count == 2 else {
            throw OBDServicePIDError.invalidRequest("Mode 22 PID must be 4 hex chars (2 bytes). Got: \(cleaned)")
        }

        let bytes = try await requestRawPID("22" + cleaned, retries: retries)

        guard bytes.count >= 3 else {
            throw OBDServicePIDError.invalidResponse("Mode 22 response too short")
        }
        guard bytes[0] == 0x62 else {
            throw OBDServicePIDError.invalidResponse("Expected 0x62 response, got \(String(format: "0x%02X", bytes[0]))")
        }
        guard bytes[1] == pidBytes[0], bytes[2] == pidBytes[1] else {
            throw OBDServicePIDError.invalidResponse("Mode 22 PID echo mismatch. Expected \(cleaned), got \(String(format: "%02X%02X", bytes[1], bytes[2]))")
        }

        // Data starts after 62 PIDHi PIDLo
        return Array(bytes.dropFirst(3))
    }

    /// Batch Mode 22 requests (cannot be combined into one message like Mode 01).
    func requestMode22PIDs(_ pids: [String], retries: Int = 10) async throws -> [String: [UInt8]] {
        var results: [String: [UInt8]] = [:]
        for pid in pids {
            results[pid] = try await requestMode22(pid, retries: retries)
        }
        return results
    }

    /// Mode 21 request.
    /// Example PID: "46" -> sends "2146" -> expects "6146..."
    func requestMode21(_ pid: String, retries: Int = 10) async throws -> [UInt8] {
        let cleaned = pid.trimmed.uppercased()
        guard cleaned.count == 2, let pidBytes = hexToBytes(cleaned), pidBytes.count == 1 else {
            throw OBDServicePIDError.invalidRequest("Mode 21 PID must be 2 hex chars (1 byte). Got: \(cleaned)")
        }

        let bytes = try await requestRawPID("21" + cleaned, retries: retries)

        guard bytes.count >= 2 else {
            throw OBDServicePIDError.invalidResponse("Mode 21 response too short")
        }
        guard bytes[0] == 0x61 else {
            throw OBDServicePIDError.invalidResponse("Expected 0x61 response, got \(String(format: "0x%02X", bytes[0]))")
        }
        guard bytes[1] == pidBytes[0] else {
            throw OBDServicePIDError.invalidResponse("Mode 21 PID echo mismatch. Expected \(cleaned), got \(String(format: "%02X", bytes[1]))")
        }

        // Data starts after 61 PID
        return Array(bytes.dropFirst(2))
    }

    /// Batch Mode 21 requests.
    func requestMode21PIDs(_ pids: [String], retries: Int = 10) async throws -> [String: [UInt8]] {
        var results: [String: [UInt8]] = [:]
        for pid in pids {
            results[pid] = try await requestMode21(pid, retries: retries)
        }
        return results
    }
}

// MARK: - NEW Errors for PID requests

public enum OBDServicePIDError: Error, LocalizedError {
    case invalidRequest(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let msg): return msg
        case .invalidResponse(let msg): return msg
        }
    }
}

// MARK: - NEW Hex + String helpers

private func hexToBytes(_ hex: String) -> [UInt8]? {
    let s = hex.replacingOccurrences(of: " ", with: "").uppercased()
    guard s.count % 2 == 0 else { return nil }

    var out: [UInt8] = []
    out.reserveCapacity(s.count / 2)

    var idx = s.startIndex
    while idx < s.endIndex {
        let next = s.index(idx, offsetBy: 2)
        let byteStr = String(s[idx..<next])
        guard let b = UInt8(byteStr, radix: 16) else { return nil }
        out.append(b)
        idx = next
    }
    return out
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
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

import Combine
import Foundation

public struct LiveStreamResult: Equatable {
    public let mode01: [OBDCommand: MeasurementResult]
    public let mode22: [String: [UInt8]]   // key = "F442" etc (no "22" prefix)
    public let mode21: [String: [UInt8]]   // key = "46" etc (no "21" prefix)

    public init(
        mode01: [OBDCommand: MeasurementResult],
        mode22: [String: [UInt8]],
        mode21: [String: [UInt8]]
    ) {
        self.mode01 = mode01
        self.mode22 = mode22
        self.mode21 = mode21
    }
}

public extension OBDService {

    /// Streams Mode 01 + Mode 22 + Mode 21 together on a timer.
    /// - mode22PIDs: pass ["F442", ...] (no "22" prefix)
    /// - mode21PIDs: pass ["46", ...]   (no "21" prefix)
    func startContinuousLiveStream(
        mode01: [OBDCommand],
        mode22PIDs: [String],
        mode21PIDs: [String],
        unit: MeasurementUnit = .metric,
        interval: TimeInterval = 0.3
    ) -> AnyPublisher<LiveStreamResult, Error> {

        Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .flatMap { [weak self] _ -> Future<LiveStreamResult, Error> in
                Future { promise in
                    guard let self else {
                        promise(.failure(OBDServiceError.notConnectedToVehicle))
                        return
                    }

                    Task(priority: .userInitiated) {
                        do {
                            // Mode 01 (batched)
                            let mode01Result: [OBDCommand: MeasurementResult]
                            if mode01.isEmpty {
                                mode01Result = [:]
                            } else {
                                mode01Result = try await self.requestPIDs(mode01, unit: unit)
                            }

                            // Mode 22 (one-by-one)
                            let mode22Result: [String: [UInt8]]
                            if mode22PIDs.isEmpty {
                                mode22Result = [:]
                            } else {
                                mode22Result = try await self.requestMode22PIDs(mode22PIDs)
                            }

                            // Mode 21 (one-by-one)
                            let mode21Result: [String: [UInt8]]
                            if mode21PIDs.isEmpty {
                                mode21Result = [:]
                            } else {
                                mode21Result = try await self.requestMode21PIDs(mode21PIDs)
                            }

                            promise(.success(
                                LiveStreamResult(
                                    mode01: mode01Result,
                                    mode22: mode22Result,
                                    mode21: mode21Result
                                )
                            ))
                        } catch {
                            promise(.failure(error))
                        }
                    }
                }
            }
            .eraseToAnyPublisher()
    }
}
