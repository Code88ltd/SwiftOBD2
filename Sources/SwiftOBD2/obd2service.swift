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
/// Terminates the connection with the OBD2 adapter.
public func stopConnection() {
    elm327.stopConnection()
}

public actor OBDRequestLock {
    public init() {}
    public func withLock<T>(_ op: () async throws -> T) async throws -> T {
        try await op()
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

    private var elm327: ELM327
    private var cancellables = Set<AnyCancellable>()
    private let requestLock = OBDRequestLock()

    // MARK: - Logging helpers

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

    public init(connectionType: ConnectionType = .bluetooth) {
        self.connectionType = connectionType
#if targetEnvironment(simulator)
        elm327 = ELM327(comm: MOCKComm())
#else
        switch connectionType {
        case .bluetooth:
            elm327 = ELM327(comm: BLEManager())
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

    // MARK: - Request Handling

    public func requestPIDs(_ commands: [OBDCommand], unit: MeasurementUnit) async throws -> [OBDCommand: MeasurementResult] {
        try await requestLock.withLock {
            let pidList = commands.map { $0.properties.command }.joined(separator: ", ")
            obdDebug("Batch request: [\(pidList)]", category: .communication)

            let message = "01" + commands.compactMap { $0.properties.command.dropFirst(2) }.joined()
            let response = try await sendCommandInternal(message, retries: 10)

            guard let responseData = try elm327.canProtocol?.parse(response).first?.data else {
                obdWarning("Batch parse produced no frames for [\(pidList)]", category: .communication)
                return [:]
            }

            var batchedResponse = BatchedResponse(response: responseData, unit)

            let results: [OBDCommand: MeasurementResult] = commands.reduce(into: [:]) { result, command in
                let measurement = batchedResponse.extractValue(command)
                if let measurement {
                    result[command] = measurement
                } else {
                    obdWarning(
                        "NO DATA in batch for PID \(command.properties.command)",
                        category: .communication
                    )
                }
            }

            return results
        }
    }

    public func sendCommandInternal(_ message: String, retries: Int) async throws -> [String] {
        let id = nextRequestID()
        let start = CFAbsoluteTimeGetCurrent()

        obdDebug(
            "TX [#\(id)] → \(message) (retries=\(retries))",
            category: .communication
        )

        do {
            let lines = try await elm327.sendCommand(message, retries: retries)
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            let formatted = formatLines(lines)

            if isLikelyNoData(lines) {
                obdWarning(
                    "RX [#\(id)] ← NO DATA (\(ms)ms) :: \(formatted)",
                    category: .communication
                )
            } else {
                obdDebug(
                    "RX [#\(id)] ← (\(ms)ms) :: \(formatted)",
                    category: .communication
                )
            }

            return lines
        } catch {
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            obdError(
                "ERR [#\(id)] \(message) (\(ms)ms) :: \(error.localizedDescription)",
                category: .communication
            )
            throw OBDServiceError.commandFailed(command: message, error: error)
        }
    }

    private func switchConnectionType(_ connectionType: ConnectionType) {
        elm327.stopConnection()
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
