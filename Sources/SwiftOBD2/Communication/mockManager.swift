//
//  MOCKComm.swift
//
//  Realistic stateful ECU mock
//

import Foundation
import OSLog
import CoreBluetooth

// MARK: - Commands / Settings

enum CommandAction {
    case setHeaderOn
    case setHeaderOff
    case echoOn
    case echoOff
}

struct MockECUSettings {
    var headerOn = true
    var echo = false
    var vinNumber = ""
}

// MARK: - Vehicle Simulator (STATEFUL)

final class MockVehicleSim {

    static let shared = MockVehicleSim()

    private init() {}

    private var lastUpdate = Date()

    // Core state
    private var throttle: Double = 0.12
    private var targetThrottle: Double = 0.12

    private(set) var rpm: Double = 850
    private(set) var speedKph: Double = 0
    private(set) var coolantC: Double = 25
    private(set) var intakeC: Double = 20
    private(set) var loadPct: Double = 18
    private(set) var maf: Double = 3.0
    private(set) var voltage: Double = 12.5
    private(set) var fuelPct: Double = 74

    func step() {
        let now = Date()
        var dt = now.timeIntervalSince(lastUpdate)
        lastUpdate = now
        dt = min(max(dt, 0.02), 0.4)

        // Occasionally change throttle (simulate driver)
        if Double.random(in: 0...1) < 0.05 {
            targetThrottle = Double.random(in: 0.1...0.7)
        }

        // Smooth throttle
        throttle = approach(throttle, targetThrottle, rate: 2.0, dt: dt)

        // RPM model
        let idle = speedKph > 1 ? 900.0 : 820.0
        let targetRPM = idle + throttle * 4200 + speedKph * 15
        rpm = approach(rpm, targetRPM, rate: 3.0, dt: dt)

        // Speed model
        let accel = throttle * 12 + max(0, (rpm - 1200) / 1000)
        let drag = speedKph * 0.22
        speedKph = clamp(speedKph + (accel - drag) * dt, 0, 180)

        // Load
        let targetLoad = clamp(15 + throttle * 75 + speedKph * 0.06, 5, 100)
        loadPct = approach(loadPct, targetLoad, rate: 3.0, dt: dt)

        // Coolant warms slowly
        let coolantTarget = 92 + (loadPct - 20) * 0.04
        let warmRate = coolantC < 80 ? 0.18 : 0.06
        coolantC = clamp(approach(coolantC, coolantTarget, rate: warmRate, dt: dt), 15, 115)

        // Intake temp follows ambient + engine heat
        intakeC = approach(intakeC, 18 + loadPct * 0.25, rate: 0.6, dt: dt)

        // MAF correlates to RPM + load
        maf = clamp(approach(maf, (rpm / 800) * (1 + loadPct / 100) * 2.8, rate: 2.0, dt: dt), 2, 150)

        // Voltage
        let vTarget = rpm > 900 ? 13.9 : 12.4
        voltage = approach(voltage, vTarget, rate: 1.2, dt: dt)

        // Fuel burn (very slow)
        if speedKph > 5 {
            fuelPct = clamp(fuelPct - dt * (0.002 + loadPct * 0.00004), 0, 100)
        }
    }

    // MARK: - Helpers

    private func approach(_ current: Double, _ target: Double, rate: Double, dt: Double) -> Double {
        let delta = target - current
        return current + delta * min(1, rate * dt)
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(v, lo), hi)
    }
}

// MARK: - MOCKComm

final class MOCKComm: CommProtocol {

    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "BLE", category: "MOCKComm")

    @Published var connectionState: ConnectionState = .disconnected
    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }

    var obdDelegate: OBDServiceDelegate?
    var ecuSettings: MockECUSettings = .init()

    func sendCommand(_ command: String, retries: Int = 3) async throws -> [String] {

        MockVehicleSim.shared.step()

        let sim = MockVehicleSim.shared
        var header = ecuSettings.headerOn ? "7E8 " : ""

        guard let obd = OBDCommand.from(command: command) else {
            return ["NO DATA"]
        }

        switch obd {

        case .mode1(let pid):

            switch pid {

            case .rpm:
                let v = Int(sim.rpm * 4)
                return ["\(header)41 0C \(hex(v / 256)) \(hex(v % 256))"]

            case .speed:
                return ["\(header)41 0D \(hex(Int(sim.speedKph)))"]

            case .coolantTemp:
                return ["\(header)41 05 \(hex(Int(sim.coolantC + 40)))"]

            case .engineLoad:
                return ["\(header)41 04 \(hex(Int(sim.loadPct / 100 * 255)))"]

            case .throttlePos:
                return ["\(header)41 11 \(hex(Int(sim.loadPct / 100 * 255)))"]

            case .maf:
                let raw = Int(sim.maf * 100)
                return ["\(header)41 10 \(hex(raw / 256)) \(hex(raw % 256))"]

            case .intakeTemp:
                return ["\(header)41 0F \(hex(Int(sim.intakeC + 40)))"]

            case .fuelLevel:
                return ["\(header)41 2F \(hex(Int(sim.fuelPct / 100 * 255)))"]

            case .controlModuleVoltage:
                let raw = Int(sim.voltage * 1000)
                return ["\(header)41 42 \(hex(raw / 256)) \(hex(raw % 256))"]

            default:
                return ["NO DATA"]
            }

        default:
            return ["NO DATA"]
        }
    }

    func disconnectPeripheral() {
        connectionState = .disconnected
        obdDelegate?.connectionStateChanged(state: .disconnected)
    }

    func connectAsync(timeout: TimeInterval, peripheral: CBPeripheral? = nil) async throws {
        connectionState = .connectedToAdapter
        obdDelegate?.connectionStateChanged(state: .connectedToAdapter)
    }

    func scanForPeripherals() async throws {}
}

// MARK: - Utils

private func hex(_ v: Int) -> String {
    String(format: "%02X", max(0, min(255, v)))
}
