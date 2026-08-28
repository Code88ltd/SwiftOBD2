import Combine
import CoreBluetooth
import ExternalAccessory
import Foundation
import OSLog

public final class EAManager:
    NSObject,
    CommProtocol,
    StreamDelegate {

    // MARK: - Connection State

    @Published
    var connectionState:
        ConnectionState = .disconnected

    var connectionStatePublisher:
        Published<ConnectionState>.Publisher {

        $connectionState
    }

    weak var obdDelegate:
        OBDServiceDelegate?

    // MARK: - Logging

    private let logger =
        Logger(
            subsystem:
                Bundle.main.bundleIdentifier
                ?? "com.swiftobd2.app",
            category:
                "EAManager"
        )

    // MARK: - External Accessory

    private let protocolString =
        "com.obdlink"

    private let logCategory =
        "EA"

    private var attemptId =
        ""

    private var selectedAdapterLabel =
        "OBDLink (EA)"

    private var lastCommand:
        String?

    // MARK: - State

    private let stateQueue =
        DispatchQueue(
            label:
                "swiftobd2.ea.state"
        )

    private var accessory:
        EAAccessory?

    private var session:
        EASession?

    private var input:
        InputStream?

    private var output:
        OutputStream?

    private var buffer =
        Data()

    private var messageCompletion:
        (([String]?, Error?) -> Void)?

    private let commandLock =
        AsyncLock()

    private var isDisconnecting =
        false

    // MARK: - Logging Helper

    private func post(
        _ level:
            SwiftOBD2LogLevel,
        _ message:
            String,
        meta:
            [String: String]? = nil
    ) {

        var m =
            meta ?? [:]

        if !attemptId.isEmpty {

            m["attemptId"] =
                attemptId
        }

        m["adapter"] =
            selectedAdapterLabel

        m["transport"] =
            "ea"

        m["protocol"] =
            protocolString

        SwiftOBD2Logger
            .post(
                level,
                category:
                    logCategory,
                message,
                meta:
                    m
            )
    }

    // MARK: - Init

    public override init() {

        super.init()

        EAAccessoryManager
            .shared()
            .registerForLocalNotifications()

        NotificationCenter
            .default
            .addObserver(
                self,
                selector:
                    #selector(
                        accessoryDidConnect(_:)
                    ),
                name:
                    .EAAccessoryDidConnect,
                object:
                    nil
            )

        NotificationCenter
            .default
            .addObserver(
                self,
                selector:
                    #selector(
                        accessoryDidDisconnect(_:)
                    ),
                name:
                    .EAAccessoryDidDisconnect,
                object:
                    nil
            )

        post(
            .info,
            "EAManager init"
        )
    }

    deinit {

        NotificationCenter
            .default
            .removeObserver(
                self
            )

        EAAccessoryManager
            .shared()
            .unregisterForLocalNotifications()

        /*
         IMPORTANT:

         Do not asynchronously dispatch back onto
         stateQueue during deinit.
        */

        performDisconnectCleanup(
            notifyDelegate:
                false
        )
    }

    // MARK: - Connect

    public func connectAsync(
        timeout:
            TimeInterval,
        peripheral _:
            CBPeripheral? = nil
    ) async throws {

        attemptId =
            UUID()
                .uuidString

        let old =
            connectionState

        connectionState =
            .connecting

        if old != connectionState {

            DispatchQueue
                .main
                .async {

                    self
                        .obdDelegate?
                        .connectionStateChanged(
                            state:
                                .connecting
                        )
                }
        }

        post(
            .info,
            "Connecting to OBDLink ExternalAccessory",
            meta: [
                "timeout":
                    "\(timeout)"
            ]
        )

        let deadline =
            Date()
                .addingTimeInterval(
                    timeout
                )

        while Date() < deadline {

            if try openSessionIfAvailable() {

                let old2 =
                    connectionState

                connectionState =
                    .connectedToAdapter

                if old2 != connectionState {

                    DispatchQueue
                        .main
                        .async {

                            self
                                .obdDelegate?
                                .connectionStateChanged(
                                    state:
                                        .connectedToAdapter
                                )
                        }
                }

                post(
                    .info,
                    "OBDLink ExternalAccessory connected"
                )

                return
            }

            try await Task
                .sleep(
                    nanoseconds:
                        250_000_000
                )
        }

        connectionState =
            .error

        DispatchQueue
            .main
            .async {

                self
                    .obdDelegate?
                    .connectionStateChanged(
                        state:
                            .error
                    )
            }

        post(
            .error,
            "OBDLink ExternalAccessory not found"
        )

        throw BLEManagerError
            .peripheralNotFound
    }

    // MARK: - Disconnect

    public func disconnectPeripheral() {

        stateQueue
            .sync {

                self
                    .performDisconnectCleanup(
                        notifyDelegate:
                            true
                    )
            }
    }

    private func performDisconnectCleanup(
        notifyDelegate:
            Bool
    ) {

        guard !isDisconnecting
        else {
            return
        }

        isDisconnecting =
            true

        defer {

            isDisconnecting =
                false
        }

        post(
            .info,
            "disconnectPeripheral",
            meta: [
                "state":
                    "\(connectionState)",

                "accessory":
                    accessory?
                        .name
                    ?? "nil"
            ]
        )

        buffer
            .removeAll()

        let completion =
            messageCompletion

        messageCompletion =
            nil

        input?
            .delegate =
            nil

        output?
            .delegate =
            nil

        input?
            .close()

        output?
            .close()

        input?
            .remove(
                from:
                    .main,
                forMode:
                    .common
            )

        output?
            .remove(
                from:
                    .main,
                forMode:
                    .common
            )

        input =
            nil

        output =
            nil

        session =
            nil

        accessory =
            nil

        lastCommand =
            nil

        completion?(
            nil,
            BLEManagerError
                .peripheralNotConnected
        )

        let old =
            connectionState

        connectionState =
            .disconnected

        if notifyDelegate,
           old != .disconnected {

            DispatchQueue
                .main
                .async { [weak self] in

                    self?
                        .obdDelegate?
                        .connectionStateChanged(
                            state:
                                .disconnected
                        )
                }
        }
    }

    // MARK: - Scan

    func scanForPeripherals() async throws {

        post(
            .debug,
            "scanForPeripherals no-op (ExternalAccessory)"
        )
    }

    // MARK: - Raw Command

    /*
     Public intentionally.

     TrackPulse's Porsche K-Line service can use
     this method directly without invoking
     OBDService / protocol detection / PID
     discovery.

     This is transport only.
    */

    public func sendCommand(
        _ command:
            String,
        retries:
            Int
    ) async throws -> [String] {

        guard
            connectionState
                == .connectedToAdapter,
            output != nil
        else {

            post(
                .warning,
                "sendCommand blocked (not ready)",
                meta: [
                    "state":
                        "\(connectionState)",

                    "hasOutput":
                        "\(output != nil)",

                    "command":
                        command
                ]
            )

            throw BLEManagerError
                .missingPeripheralOrCharacteristic
        }

        await commandLock
            .lock()

        defer {

            Task {

                await self
                    .commandLock
                    .unlock()
            }
        }

        lastCommand =
            command

        post(
            .debug,
            "sendCommand begin",
            meta: [
                "command":
                    command,

                "retries":
                    "\(retries)"
            ]
        )

        var lastError:
            Error?

        let attemptCount =
            max(
                1,
                retries
            )

        for attempt in 1...attemptCount {

            do {

                /*
                 Clear stale data before sending a
                 fresh command.

                 This prevents bytes left over from
                 an earlier adapter command being
                 interpreted as the response to the
                 new K-Line command.
                */

                stateQueue
                    .sync {

                        self
                            .buffer
                            .removeAll()
                    }

                try writeCommand(
                    command
                )

                let response =
                    try await waitForResponse(
                        timeout:
                            BLEConstants
                                .defaultTimeout
                    )

                post(
                    .debug,
                    "sendCommand response",
                    meta: [
                        "command":
                            command,

                        "attempt":
                            "\(attempt)",

                        "lines":
                            "\(response.count)",

                        "rx":
                            response
                                .joined(
                                    separator:
                                        " | "
                                )
                    ]
                )

                return response

            } catch {

                lastError =
                    error

                post(
                    .warning,
                    "sendCommand attempt failed",
                    meta: [
                        "command":
                            command,

                        "attempt":
                            "\(attempt)",

                        "error":
                            error
                                .localizedDescription
                    ]
                )

                if attempt < attemptCount {

                    try await Task
                        .sleep(
                            nanoseconds:
                                UInt64(
                                    BLEConstants
                                        .retryDelay
                                    *
                                    1_000_000_000
                                )
                        )
                }
            }
        }

        throw lastError
        ??
        BLEManagerError
            .unknownError
    }

    // MARK: - Open EA Session

    private func openSessionIfAvailable()
        throws -> Bool {

        let accessories =
            EAAccessoryManager
                .shared()
                .connectedAccessories

        guard
            let acc =
                accessories
                    .first(
                        where: {

                            $0
                                .protocolStrings
                                .contains(
                                    protocolString
                                )
                        }
                    )
        else {

            return false
        }

        accessory =
            acc

        guard
            let sess =
                EASession(
                    accessory:
                        acc,
                    forProtocol:
                        protocolString
                )
        else {

            throw BLEManagerError
                .unknownError
        }

        session =
            sess

        input =
            sess.inputStream

        output =
            sess.outputStream

        input?
            .delegate =
            self

        output?
            .delegate =
            self

        input?
            .schedule(
                in:
                    .main,
                forMode:
                    .common
            )

        output?
            .schedule(
                in:
                    .main,
                forMode:
                    .common
            )

        input?
            .open()

        output?
            .open()

        post(
            .info,
            "EA session opened",
            meta: [
                "accessory":
                    acc.name
            ]
        )

        logger
            .info(
                "EA session opened: \(acc.name, privacy: .public)"
            )

        return true
    }

    // MARK: - Write

    private func writeCommand(
        _ command:
            String
    ) throws {

        guard let output
        else {

            throw BLEManagerError
                .missingPeripheralOrCharacteristic
        }

        guard
            let data =
                "\(command)\r"
                    .data(
                        using:
                            .ascii
                    )
        else {

            throw BLEManagerError
                .stringConversionFailed
        }

        post(
            .debug,
            "TX",
            meta: [
                "command":
                    command
            ]
        )

        try data
            .withUnsafeBytes { ptr in

                guard
                    let base =
                        ptr
                            .bindMemory(
                                to:
                                    UInt8.self
                            )
                            .baseAddress
                else {

                    throw BLEManagerError
                        .incorrectDataConversion
                }

                var remaining =
                    ptr.count

                var offset =
                    0

                while remaining > 0 {

                    while !output
                        .hasSpaceAvailable {

                        Thread
                            .sleep(
                                forTimeInterval:
                                    0.01
                            )
                    }

                    let written =
                        output
                            .write(
                                base
                                    .advanced(
                                        by:
                                            offset
                                    ),
                                maxLength:
                                    remaining
                            )

                    if written < 0 {

                        throw output
                            .streamError
                        ??
                        BLEManagerError
                            .sendMessageTimeout
                    }

                    if written == 0 {

                        Thread
                            .sleep(
                                forTimeInterval:
                                    0.01
                            )

                        continue
                    }

                    remaining -=
                        written

                    offset +=
                        written
                }
            }
    }

    // MARK: - Wait For Prompt

    private func waitForResponse(
        timeout:
            TimeInterval
    ) async throws -> [String] {

        try await withTimeout(
            seconds:
                timeout,
            timeoutError:
                BLEManagerError
                    .timeout
        ) {

            try await withCheckedThrowingContinuation {
                continuation in

                self
                    .stateQueue
                    .async {

                        if self
                            .messageCompletion
                            != nil {

                            continuation
                                .resume(
                                    throwing:
                                        BLEMessageProcessorError
                                            .concurrentCommand
                                )

                            return
                        }

                        self
                            .messageCompletion = {
                                lines,
                                error in

                                self
                                    .messageCompletion =
                                    nil

                                if let lines {

                                    continuation
                                        .resume(
                                            returning:
                                                lines
                                        )

                                } else if let error {

                                    continuation
                                        .resume(
                                            throwing:
                                                error
                                        )

                                } else {

                                    continuation
                                        .resume(
                                            throwing:
                                                BLEManagerError
                                                    .timeout
                                        )
                                }
                            }
                    }
            }
        }
    }

    // MARK: - Stream Delegate

    public func stream(
        _ aStream:
            Stream,
        handle eventCode:
            Stream.Event
    ) {

        switch eventCode {

        case .hasBytesAvailable:

            if aStream === input {

                readAvailable()
            }

        case .errorOccurred:

            post(
                .error,
                "stream errorOccurred",
                meta: [
                    "stream":
                        (aStream === input)
                        ? "input"
                        : "output",

                    "error":
                        aStream
                            .streamError?
                            .localizedDescription
                        ?? "nil"
                ]
            )

            disconnectPeripheral()

        case .endEncountered:

            post(
                .warning,
                "stream endEncountered",
                meta: [
                    "stream":
                        (aStream === input)
                        ? "input"
                        : "output"
                ]
            )

            disconnectPeripheral()

        default:

            break
        }
    }

    // MARK: - Read

    private func readAvailable() {

        guard let input
        else {
            return
        }

        var tmp =
            [UInt8](
                repeating:
                    0,
                count:
                    4096
            )

        while input
            .hasBytesAvailable {

            let n =
                input
                    .read(
                        &tmp,
                        maxLength:
                            tmp.count
                    )

            if n <= 0 {

                break
            }

            stateQueue
                .async {

                    self
                        .buffer
                        .append(
                            contentsOf:
                                tmp[0..<n]
                        )

                    guard
                        let string =
                            String(
                                data:
                                    self.buffer,
                                encoding:
                                    .utf8
                            )
                    else {

                        return
                    }

                    /*
                     OBDLink/ELM command responses
                     terminate with the adapter
                     prompt ">".
                    */

                    if string
                        .contains(
                            ">"
                        ) {

                        let cleaned =
                            string
                                .replacingOccurrences(
                                    of:
                                        ">",
                                    with:
                                        ""
                                )

                        let lines =
                            cleaned
                                .components(
                                    separatedBy:
                                        .newlines
                                )
                                .map {

                                    $0
                                        .trimmingCharacters(
                                            in:
                                                .whitespacesAndNewlines
                                        )
                                }
                                .filter {

                                    !$0
                                        .isEmpty
                                }

                        let completion =
                            self
                                .messageCompletion

                        self
                            .messageCompletion =
                            nil

                        completion?(
                            lines,
                            nil
                        )

                        self
                            .buffer
                            .removeAll()
                    }
                }
        }
    }

    // MARK: - Accessory Notifications

    @objc
    private func accessoryDidConnect(
        _ note:
            Notification
    ) {

        guard
            let acc =
                note
                    .userInfo?[
                        EAAccessoryKey
                    ]
                as?
                EAAccessory
        else {

            return
        }

        if acc
            .protocolStrings
            .contains(
                protocolString
            ) {

            post(
                .info,
                "EA accessory connected",
                meta: [
                    "name":
                        acc.name
                ]
            )
        }
    }

    @objc
    private func accessoryDidDisconnect(
        _ note:
            Notification
    ) {

        guard
            let acc =
                note
                    .userInfo?[
                        EAAccessoryKey
                    ]
                as?
                EAAccessory
        else {

            return
        }

        if acc.connectionID
            ==
            accessory?
                .connectionID {

            post(
                .warning,
                "EA accessory disconnected",
                meta: [
                    "name":
                        acc.name
                ]
            )

            disconnectPeripheral()
        }
    }
}
