import Foundation

// MARK: - App log bridge event name (module -> app)

public extension Notification.Name {
    static let obdLogEvent = Notification.Name("obdLogEvent")
}

// MARK: - NotificationCenter log bridge helper
// Posts logs from SwiftOBD2 module so the host app can forward them into LogStore.shared.

@inline(__always)
func postOBDLogEvent(level: String, category: OBDLogger.Category, message: String) {
    let payload: [String: Any] = [
        "level": level,
        "category": category.rawValue,
        "message": message
    ]

    if Thread.isMainThread {
        NotificationCenter.default.post(name: .obdLogEvent, object: nil, userInfo: payload)
    } else {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .obdLogEvent, object: nil, userInfo: payload)
        }
    }
}
