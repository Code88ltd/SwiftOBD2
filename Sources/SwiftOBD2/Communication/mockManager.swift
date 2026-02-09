//
//  MOCKComm.swift
//
//  Created by kemo konteh on 3/16/24.
//  Updated: Realistic stateful PID simulation + keeps ELM/AT handshake
//

import Foundation
import OSLog
import CoreBluetooth

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

// MARK: - Vehicle Simulator (stateful + smooth)

final class MockVehicleSim {
    static let shared = MockVehicleSim()
    private init() {}

    private var lastUpdate = Date()

    // Driver intent
    private var throttle: Double = 0.12
    private var targetThrottle: Double = 0.12

    // State
    private(set) var rpm: Double = 850
    private(set) var speedKph: Double = 0
    private(set) var coolantC: Double = 25
    private(set) var intakeC: Double = 18
    private(set) var loadPct: Double = 18
    private(set) var maf: Double = 3.0
    private(set) var voltage: Double = 12.4
    private(set) var fuelPct: Double = 74

    func step() {
        let now = Date()
        var dt = now.timeIntervalSince(lastUpdate)
        lastUpdate = now
        dt = min(max(dt, 0.02), 0.4)

        // Occasionally change throttle target (simulate human)
        if Double.random(in: 0...1) < 0.05 {
            // bias towards mild driving, with occasional larger pulls
            let pick = Double.random(in: 0...1)
            if pick < 0.75 { targetThrottle = Double.random(in: 0.12...0.45) }
            else { targetThrottle = Double.random(in: 0.45...0.85) }
        }

        // Smooth throttle
        throttle = approach(throttle, targetThrottle, rate: 2.0, dt: dt)

        // RPM model: idle + throttle + speed influence
        let idle = (speedKph > 2) ? 900.0 : 820.0
        let targetRPM = idle + throttle * 4200 + speedKph * 14
        rpm = clamp(approach(rpm, targetRPM, rate: 3.2, dt: dt), 750, 6500)

        // Speed model: accel from throttle/rpm minus drag
        let accel = throttle * 12.0 + max(0, (rpm - 1200) / 1200) * 3.0
        let drag = speedKph * 0.22
        speedKph = clamp(speedKph + (accel - drag) * dt, 0, 190)

        // Load: correlated with throttle and speed
        let targetLoad = clamp(15 + throttle * 75 + speedKph * 0.06, 5, 100)
        loadPct = approach(loadPct, targetLoad, rate: 3.0, dt: dt)

        // Coolant warms slowly towards ~90–100 depending on load
        let coolantTarget = 92 + (loadPct - 20) * 0.05
        let warmRate = coolantC < 80 ? 0.18 : 0.07
        coolantC = clamp(approach(coolantC, coolantTarget, rate: warmRate, dt: dt), 10, 115)

        // Intake temp follows ambient + engine bay heat
        intakeC = approach(intakeC, 18 + loadPct * 0.22, rate: 0.6, dt: dt)

        // MAF scales with rpm and load (g/s-ish)
        maf = clamp(approach(maf, (rpm / 900) * (1.0 + loadPct / 100) * 2.4, rate: 2.2, dt: dt), 2, 200)

        // Voltage: alternator kicks in when "running"
        let vTarget = rpm > 900 ? 13.9 : 12.4
        voltage = approach(voltage, vTarget, rate: 1.2, dt: dt)

        // Fuel burn: very slow
        if speedKph > 5 {
            fuelPct = clamp(fuelPct - dt * (0.002 + loadPct * 0.00004), 0, 100)
        }
    }

    private func approach(_ current: Double, _ target: Double, rate: Double, dt: Double) -> Double {
        let delta = target - current
        return current + delta * min(1, rate * dt)
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(v, lo), hi)
    }
}

final class MOCKComm: CommProtocol {
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.app", category: "MOCKComm")

    @Published var connectionState: ConnectionState = .disconnected
    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }
    var obdDelegate: OBDServiceDelegate?

    var ecuSettings: MockECUSettings = .init()

    func sendCommand(_ command: String, retries: Int = 3) async throws -> [String] {
        logger.info("Sending command: \(command, privacy: .public)")
        var header = ""

        // ✅ advance simulator each command so values evolve smoothly
        MockVehicleSim.shared.step()

        let prefix = String(command.prefix(2))

        // MARK: - Modes 01 / 06 / 09 framing (your existing implementation)
        if prefix == "01" || prefix == "06" || prefix == "09" {
            var response: String = ""
            if ecuSettings.headerOn {
                header = "7E8"
            }

            for i in stride(from: 2, to: command.count, by: 2) {
                let index = command.index(command.startIndex, offsetBy: i)
                let nextIndex = command.index(command.startIndex, offsetBy: i + 2)
                let subCommand = prefix + String(command[index..<nextIndex])

                guard let value = OBDCommand.mockResponse(forCommand: subCommand) else {
                    return ["No Data"]
                }
                response.append(value + " ")
            }

            guard var mode = Int(command.prefix(2)) else {
                return [""]
            }
            mode = mode + 40

            // Multi-frame (long) response
            if response.count > 18 {
                var chunks = response.chunked(by: 15)
                var ff = chunks[0]

                var totalLength = 0
                let ffLength = ff.replacingOccurrences(of: " ", with: "").count / 2
                totalLength += ffLength

                var cf = Array(chunks.dropFirst())
                totalLength += cf.joined().replacingOccurrences(of: " ", with: "").count

                var lengthHex = String(format: "%02X", totalLength - 1)

                if lengthHex.count % 2 != 0 {
                    lengthHex = "0" + lengthHex
                }

                lengthHex = "10 " + lengthHex
                ff = lengthHex + " " + String(mode) + " " + ff

                var assembledFrame: [String] = [ff]
                var cfCount = 33
                for i in 0..<cf.count {
                    let length = String(format: "%02X", cfCount)
                    cfCount += 1
                    cf[i] = length + " " + cf[i]
                    assembledFrame.append(cf[i])
                }

                for i in 0..<assembledFrame.count {
                    assembledFrame[i] = header + " " + assembledFrame[i]
                    while assembledFrame[i].count < 28 {
                        assembledFrame[i].append("00 ")
                    }
                }

                if ecuSettings.echo {
                    assembledFrame.insert(" \(command)", at: 0)
                }
                return assembledFrame.map { String($0) }
            } else {
                // Single-frame response
                let lengthHex = String(format: "%02X", response.count / 3)
                response = header + " " + lengthHex + " "  + String(mode) + " " + response
                while response.count < 28 {
                    response.append("00 ")
                }
                if ecuSettings.echo {
                    response = " \(command)" + response
                }
                return [response]
            }
        }

        // MARK: - AT commands (ELM handshake) ✅ KEEP THIS
        else if command.hasPrefix("AT") {
            let action = command.dropFirst(2)
            var response = {
                switch action {
                case " SH 7E0", "D", "L0", "AT1", "SP0", "SP6", "STFF", "S0":
                    return ["OK"]
                case "Z":
                    return ["ELM327 v1.5"]
                case "H1":
                    ecuSettings.headerOn = true
                    return ["OK"]
                case "H0":
                    ecuSettings.headerOn = false
                    return ["OK"]
                case "E1":
                    ecuSettings.echo = true
                    return ["OK"]
                case "E0":
                    ecuSettings.echo = false
                    return ["OK"]
                case "DPN":
                    return ["06"]
                case "RV":
                    // Use simulator voltage (stable) instead of random
                    let v = MockVehicleSim.shared.voltage
                    return [String(format: "%.2f", v)]
                default:
                    return ["NO DATA"]
                }
            }()

            if ecuSettings.echo {
                response.insert(command, at: 0)
            }
            return response
        }

        // MARK: - Mode 03 (DTCs) ✅ KEEP THIS
        else if command == "03" {
            if ecuSettings.headerOn {
                header = "7E8"
            }

            let dtcs = Self.randomDTCs()

            if dtcs.isEmpty {
                var response = "43 00 00"
                let length = String(format: "%02X", response.count / 3 + 1)
                response = header + " " + length + " " + response
                while response.count < 26 { response.append(" 00") }
                return [response]
            }

            var payloadBytes: [UInt8] = []
            for dtc in dtcs {
                let (a, b) = Self.encodeDTC(dtc)
                payloadBytes.append(a)
                payloadBytes.append(b)
            }

            let payloadHex = payloadBytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            var response = "43 " + payloadHex

            let length = String(format: "%02X", response.count / 3 + 1)
            response = header + " " + length + " " + response
            while response.count < 26 { response.append(" 00") }
            return [response]
        }

        // MARK: - Fallback (legacy style)
        else {
            guard var response = OBDCommand.mockResponse(forCommand: command) else {
                return ["No Data"]
            }
            response = command + response  + "\r\n\r\n>"
            var lines = response
                .components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            lines.removeLast()
            return lines
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

    func scanForPeripherals() async throws {
        // no-op for mock
    }
}

// MARK: - DTC Randomization Helpers

private extension MOCKComm {
    static func randomDTCs() -> [String] {
        let pool: [String] = [
            "P0104","P0171","P0300","P0420","P0455","P0500","P0700",
            "U0100","U0101","U0121","U0207",
            "C0035","C0040",
            "B0020","B0051"
        ]
        let count = Int.random(in: 0...4)
        return Array(pool.shuffled().prefix(count))
    }

    static func encodeDTC(_ code: String) -> (UInt8, UInt8) {
        let chars = Array(code.uppercased())
        guard chars.count == 5 else { return (0x00, 0x00) }

        let first2: UInt8 = {
            switch chars[0] {
            case "P": return 0b00
            case "C": return 0b01
            case "B": return 0b10
            case "U": return 0b11
            default:  return 0b00
            }
        }()

        let d1 = UInt8(String(chars[1])) ?? 0
        let d1_2bits = d1 & 0b11

        let d2 = UInt8(String(chars[2]), radix: 16) ?? 0
        let d3 = UInt8(String(chars[3]), radix: 16) ?? 0
        let d4 = UInt8(String(chars[4]), radix: 16) ?? 0

        let byteA: UInt8 = (first2 << 6) | (d1_2bits << 4) | (d2 & 0x0F)
        let byteB: UInt8 = ((d3 & 0x0F) << 4) | (d4 & 0x0F)
        return (byteA, byteB)
    }
}

// MARK: - Mock PID responses (NOW STATEFUL)

extension OBDCommand {
    static func mockResponse(forCommand command: String) -> String? {

        guard let obd2Command = self.from(command: command) else {
            obdWarning("Invalid mock command: \(command)", category: .communication)
            return "Invalid command"
        }

        let sim = MockVehicleSim.shared

        switch obd2Command {
        case .mode1(let command):
            switch command {

            case .pidsA:
                return "00 BE 3F A8 13 00"
            case .status:
                return "01 12 34 56 78 00"

            case .controlModuleVoltage:   // PID 0x42
                // volts = (256*A + B) / 1000
                let raw = Int(sim.voltage * 1000.0)
                let A = raw / 256
                let B = raw % 256
                return "42 \(String(format: "%02X", A)) \(String(format: "%02X", B))"

            case .pidsB:
                return "20 90 07 E0 11 00"
            case .pidsC:
                return "40 FA DC 80 00 00"
            case .pidsD:
                return "60 FF FF FF FF 00"
            case .pidsE:
                return "80 FF FF F1 FF 00"
            case .pidsF:
                return "A0 FF 80 00 01 00"
            case .pidsG:
                return "C0 3F 00 00 00 00"

            case .rpm:
                // RPM = ((A*256)+B)/4
                let desiredRPM = Int(sim.rpm.rounded())
                let decimalRep = desiredRPM * 4
                let A = decimalRep / 256
                let B = decimalRep % 256
                return "0C \(String(format: "%02X", A)) \(String(format: "%02X", B))"

            case .speed:
                // km/h in A
                return "0D \(String(format: "%02X", Int(sim.speedKph.rounded())))"

            case .coolantTemp:
                // tempC = A - 40
                let a = Int(sim.coolantC.rounded()) + 40
                return "05 \(String(format: "%02X", a))"

            case .maf:
                // MAF = ((A*256)+B)/100 (g/s)
                let raw = Int(sim.maf * 100.0)
                let A = raw / 256
                let B = raw % 256
                return "10 \(String(format: "%02X", A)) \(String(format: "%02X", B))"

            case .engineLoad:
                // load% = (A*100)/255
                let a = Int((sim.loadPct / 100.0) * 255.0)
                return "04 \(String(format: "%02X", a))"

            case .throttlePos:
                // throttle% = (A*100)/255
                let a = Int((sim.loadPct / 100.0) * 255.0)
                return "11 \(String(format: "%02X", a))"

            case .fuelLevel:
                // fuel% = (A*100)/255
                let a = Int((sim.fuelPct / 100.0) * 255.0)
                return "2F \(String(format: "%02X", a))"

            case .intakeTemp:
                let a = Int(sim.intakeC.rounded()) + 40
                return "0F \(String(format: "%02X", a))"

            // Keep the rest as your existing random-ish values (or add more sim later)
            case .fuelPressure:
                let pressure = Int.random(in: 0...765)
                let hexPressure = String(format: "%02X", pressure / 3)
                return "0A \(hexPressure)"

            case .timingAdvance:
                let advance = Int.random(in: 0...100)
                let hexAdvance = String(format: "%02X", advance / 2)
                return "0E \(hexAdvance)"

            case .intakePressure:
                let pressure = Int.random(in: 20...110)
                let hexPressure = String(format: "%02X", pressure)
                return "0B \(hexPressure)"

            case .barometricPressure:
                let pressure = Int.random(in: 95...105)
                let hexPressure = String(format: "%02X", pressure)
                return "33 \(hexPressure)"

            case .engineOilTemp:
                // correlate loosely with coolant
                let oil = min(130, max(40, Int(sim.coolantC + Double.random(in: 5...20))))
                let hex = String(format: "%02X", oil + 40)
                return "5C \(hex)"

            case .runTime:
                let runtime = Int.random(in: 0...65535)
                let A = runtime / 256
                let B = runtime % 256
                return "1F \(String(format: "%02X", A)) \(String(format: "%02X", B))"

            default:
                return nil
            }

        case .mode6(let command):
            switch command {
            case .MIDS_A: return "00 C0 00 00 01 00"
            case .MIDS_B: return "02 C0 00 00 01 00"
            case .MIDS_C: return "04 C0 00 00 01 00"
            case .MIDS_D: return "06 C0 00 00 01 00"
            case .MIDS_E: return "08 C0 00 00 01 00"
            case .MIDS_F: return "0A C0 00 00 01 00"
            default: return nil
            }

        case .mode9(let command):
            switch command {
            case .PIDS_9A:
                return "00 55 40 00 00 00"
            case .VIN:
                return "01 01 31 4E 24 41 4C 33 40 50 37 44 43 31 39 39 35 35 33"
            default:
                return nil
            }

        default:
            obdDebug("No mock response for command: \(command)", category: .communication)
            return nil
        }
    }
}

// MARK: - Utilities

extension String {
    func chunked(by chunkSize: Int) -> Array<String> {
        return stride(from: 0, to: self.count, by: chunkSize).map {
            String(
                self[self.index(self.startIndex, offsetBy: $0)..<self.index(self.startIndex, offsetBy: min($0 + chunkSize, self.count))]
            )
        }
    }
}
