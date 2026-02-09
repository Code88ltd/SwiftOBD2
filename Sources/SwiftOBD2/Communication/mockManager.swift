//
//  MOCKComm.swift
//
//
//  Created by kemo konteh on 3/16/24.
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

final class MOCKComm: CommProtocol {
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.app", category: "MOCKComm")

    @Published var connectionState: ConnectionState = .disconnected
    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }
    var obdDelegate: OBDServiceDelegate?

    var ecuSettings: MockECUSettings = .init()

    func sendCommand(_ command: String, retries: Int = 3) async throws -> [String] {
        logger.info("Sending command: \(command)")
        var header = ""

        let prefix = String(command.prefix(2))
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

            if response.count > 18 {
                var chunks = response.chunked(by: 15)
                var ff = chunks[0]

                var Totallength = 0
                let ffLength = ff.replacingOccurrences(of: " ", with: "").count / 2
                Totallength += ffLength

                var cf = Array(chunks.dropFirst())
                Totallength += cf.joined().replacingOccurrences(of: " ", with: "").count

                var lengthHex = String(format: "%02X", Totallength - 1)

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
        } else if command.hasPrefix("AT") {
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
                    return [String(Double.random(in: 12.0 ... 14.0))]
                default:
                    return ["NO DATA"]
                }
            }()
            if ecuSettings.echo {
                response.insert(command, at: 0)
            }
            return response

        } else if command == "03" {
            // ✅ Mode 03 (DTCs) — randomize every time you scan/request DTCs.
            if ecuSettings.headerOn {
                header = "7E8"
            }

            // Pick a random set each time (0–4 codes)
            let dtcs = Self.randomDTCs()

            // If no DTCs, return a valid "no codes" response.
            if dtcs.isEmpty {
                var response = "43 00 00"
                let length = String(format: "%02X", response.count / 3 + 1)
                response = header + " " + length + " " + response
                while response.count < 26 { response.append(" 00") }
                return [response]
            }

            // Encode DTCs into bytes per SAE J2012/OBD-II
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

        } else {
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
        // Expand this list whenever you want more variety.
        let pool: [String] = [
            "P0104","P0171","P0300","P0420","P0455","P0500","P0700",
            "U0100","U0101","U0121","U0207",
            "C0035","C0040",
            "B0020","B0051"
        ]

        // 0–4 codes per scan
        let count = Int.random(in: 0...4)
        return Array(pool.shuffled().prefix(count))
    }

    /// Encodes a DTC like "P0300" into two bytes.
    /// Byte A: [type(2 bits)][digit1(2 bits)][digit2(4 bits)]
    /// Byte B: [digit3(4 bits)][digit4(4 bits)]
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

// MARK: - Mock PID responses

extension OBDCommand {
    static func mockResponse(forCommand command: String) -> String? {

        guard let obd2Command = self.from(command: command) else {
            obdWarning("Invalid mock command: \(command)", category: .communication)
            return "Invalid command"
        }

        switch obd2Command {
        case .mode1(let command):
            switch command {
            case .pidsA:
                return "00 BE 3F A8 13 00"
            case .status:
                return "01 12 34 56 78 00"

            case .controlModuleVoltage:   // PID 0x42
                // 01 42 => returns A,B where volts = (256*A + B) / 1000
                let volts = Double.random(in: 11.8...14.8)
                let raw = Int(volts * 1000.0)
                let A = raw / 256
                let B = raw % 256

                let hexA = String(format: "%02X", A)
                let hexB = String(format: "%02X", B)

                return "42 \(hexA) \(hexB)"

            case .pidsB:
                return "20 90 07 E0 11 00"
            case .pidsC:
                return "40 FA DC 80 00 00"

            case .pidsD:
                // 0160 supports 61–80.
                return "60 FF FF FF FF 00"

            case .pidsE:
                // 0180 supports 81–A0.
                return "80 FF FF F1 FF 00"

            case .pidsF:
                // 01A0 supports A1–C0.
                return "A0 FF 80 00 01 00"

            case .pidsG:
                // 01C0 supports C1–E0.
                return "C0 3F 00 00 00 00"

            case .rpm:
                let desiredRPM = Int.random(in: 1000...3000)
                let decimalRep = desiredRPM * 4

                let A = decimalRep / 256
                let B = decimalRep % 256

                let hexA = String(format: "%02X", A)
                let hexB = String(format: "%02X", B)

                return "0C \(hexA) \(hexB)"

            case .speed:
                let hexSpeed = String(format: "%02X", Int.random(in: 0...100))
                return "0D \(hexSpeed)"

            case .coolantTemp:
                let temp = Int.random(in: 50...150) + 40
                let hexTemp = String(format: "%02X", temp)
                return "05 \(hexTemp)"

            case .maf:
                let maf = Int.random(in: 0...655) * 100
                let A = maf / 256
                let B = maf % 256

                let hexA = String(format: "%02X", A)
                let hexB = String(format: "%02X", B)

                return "10 \(hexA) \(hexB)"

            case .engineLoad:
                let load = Int.random(in: 0...100)
                let hexLoad = String(format: "%02X", load)
                return "04 \(hexLoad)"

            case .throttlePos:
                let pos = Int.random(in: 0...100)
                let hexPos = String(format: "%02X", pos)
                return "11 \(hexPos)"

            case .fuelLevel:
                let level = Int.random(in: 0...100)
                let hexLevel = String(format: "%02X", Double(level) * 2.55)
                return "2F \(hexLevel)"

            case .fuelPressure:
                let pressure = Int.random(in: 0...765)
                let hexPressure = String(format: "%02X", pressure / 3)
                return "0A \(hexPressure)"

            case .intakeTemp:
                let temp = Int.random(in: 0...100) + 40
                let hexTemp = String(format: "%02X", temp)
                return "0F \(hexTemp)"

            case .timingAdvance:
                let advance = Int.random(in: 0...100)
                let hexAdvance = String(format: "%02X", advance / 2)
                return "0E \(hexAdvance)"

            case .intakePressure:
                let pressure = Int.random(in: 0...255)
                let hexPressure = String(format: "%02X", pressure)
                return "0B \(hexPressure)"

            case .barometricPressure:
                let pressure = Int.random(in: 0...255)
                let hexPressure = String(format: "%02X", pressure)
                return "33 \(hexPressure)"

            case .fuelType:
                return "01 01"

            case .fuelRailPressureDirect:
                let pressure = Int.random(in: 0...655) * 100
                let A = pressure / 256
                let B = pressure % 256

                let hexA = String(format: "%02X", A)
                let hexB = String(format: "%02X", B)
                return "23 \(hexA) \(hexB)"

            case .ethanoPercent:
                let fuel = Int.random(in: 0...100)
                let hexFuel = String(format: "%02X", fuel)
                return "52 \(hexFuel)"

            case .engineOilTemp:
                let temp = Int.random(in: 0...100) + 40
                let hexTemp = String(format: "%02X", temp)
                return "5C \(hexTemp)"

            case .fuelInjectionTiming:
                let timing = Int.random(in: 0...655) * 100
                let A = timing / 256
                let B = timing % 256

                let hexA = String(format: "%02X", A)
                let hexB = String(format: "%02X", B)
                return "5D \(hexA) \(hexB)"

            case .fuelRate:
                let rate = Int.random(in: 3...120)
                let A = rate / 256
                let B = rate % 256

                let hexA = String(format: "%02X", A)
                let hexB = String(format: "%02X", B)
                return "5E \(hexA) \(hexB)"

            case .emissionsReq:
                return "01 01"

            case .runTime:
                let runtime = Int.random(in: 0...655) * 100
                let A = runtime / 256
                let B = runtime % 256

                let hexA = String(format: "%02X", A)
                let hexB = String(format: "%02X", B)
                return "1F \(hexA) \(hexB)"

            case .distanceSinceDTCCleared:
                let distance = Int.random(in: 100...6550)
                let A = distance / 256
                let B = distance % 256

                let hexA = String(format: "%02X", A)
                let hexB = String(format: "%02X", B)
                return "31 \(hexA) \(hexB)"

            case .distanceWMIL:
                let distance = Int.random(in: 100...6550)
                let A = distance / 256
                let B = distance % 256

                let hexA = String(format: "%02X", A)
                let hexB = String(format: "%02X", B)
                return "21 \(hexA) \(hexB)"

            case .warmUpsSinceDTCCleared:
                let warmUp = Int.random(in: 0...40)
                let hexWarmUp = String(format: "%02X", warmUp)
                return "30 00 00 \(hexWarmUp)"

            case .hybridBatteryLife:
                let life = Int.random(in: 100...65500)
                let A = life / 256
                let B = life % 256

                let hexA = String(format: "%02X", A)
                let hexB = String(format: "%02X", B)
                return "5B \(hexA) \(hexB)"

            default:
                return nil
            }

        case .mode6(let command):
            switch command {
            case .MIDS_A:
                return "00 C0 00 00 01 00"
            case .MIDS_B:
                return "02 C0 00 00 01 00"
            case .MIDS_C:
                return "04 C0 00 00 01 00"
            case .MIDS_D:
                return "06 C0 00 00 01 00"
            case .MIDS_E:
                return "08 C0 00 00 01 00"
            case .MIDS_F:
                return "0A C0 00 00 01 00"
            default:
                return nil
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
