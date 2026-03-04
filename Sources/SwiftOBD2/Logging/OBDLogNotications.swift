import Foundation

public enum SwiftOBD2LogLevel: String, Codable, Sendable {
    case debug, info, warning, error
}

public struct SwiftOBD2LogEvent: Codable, Sendable {
    public let timestamp: Date
    public let level: SwiftOBD2LogLevel
    public let category: String
    public let message: String
    public let meta: [String: String]?

    public init(
        timestamp: Date = Date(),
        level: SwiftOBD2LogLevel,
        category: String,
        message: String,
        meta: [String: String]? = nil
    ) {
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.meta = meta
    }
}

public extension Notification.Name {
    static let swiftobd2LogEvent = Notification.Name("swiftobd2.log.event")
}

public enum SwiftOBD2Logger {
    /// Package-level logging hook used by BLE/EA/WiFi code.
    public static func post(
        _ level: SwiftOBD2LogLevel,
        category: String,
        _ message: String,
        meta: [String: String]? = nil
    ) {
        let event = SwiftOBD2LogEvent(level: level, category: category, message: message, meta: meta)

        // Keep it simple + cheap: NotificationCenter
        NotificationCenter.default.post(
            name: .swiftobd2LogEvent,
            object: nil,
            userInfo: ["event": event]
        )
    }
}
