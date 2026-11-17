import Foundation

/// The extension's settings as it last reported them, shared with the app
/// through the app group. Safari keeps the real settings in the extension's
/// own storage, which the app can't read.
struct ExtensionStatus: Codable {
    var sites: [String: Bool]   // site -> on/off
    var auto: Bool
    var seen: [String: Double]  // site -> when the extension last ran there (ms since 1970)
    var active: Double          // when the extension last ran anywhere (ms since 1970)
    var manual: [String: Bool]?  // site -> true: button only, never opens News by itself
    var manualAt: Double?        // when manual last changed in Safari (ms since 1970)
    var access: String?          // websites Safari lets it run on: "all", "some" or "none"

    /// When the extension last ran anywhere.
    var lastActive: Date? { active > 0 ? Date(timeIntervalSince1970: active / 1000) : nil }

    func lastSeen(_ site: String) -> Date? {
        seen[site].map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}

enum SharedStatus {
    static let extensionID = "com.canopysf.AutoOpenInNews.Extension"
    #if os(macOS)
    private static let group = "UC3Y84QJ83.com.canopysf.OpenInNews" // team-prefixed: no profile needed
    #else
    private static let group = "group.com.canopysf.OpenInNews"
    #endif
    private static let defaults = UserDefaults(suiteName: group)

    /// False in a build signed without the app group entitlement, where the
    /// extension's reports can't reach the app.
    static var isAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil
    }
    private static let statusKey = "extensionStatus"
    private static let manualKey = "manualSites"

    static func save(_ json: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              (try? JSONDecoder().decode(ExtensionStatus.self, from: data)) != nil else { return }
        defaults?.set(data, forKey: statusKey)
        postChanged()
    }

    private static func postChanged() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(changedName as CFString), nil, nil, true)
    }

    /// Posted across processes whenever the extension saves a report.
    private static let changedName = "com.canopysf.AutoOpenInNews.statusChanged"

    /// Yields each time the extension saves a report, so the app can update while it's open.
    static func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let box = Unmanaged.passRetained(ContinuationBox(continuation)).toOpaque()
            let center = CFNotificationCenterGetDarwinNotifyCenter()
            CFNotificationCenterAddObserver(center, box, { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<ContinuationBox>.fromOpaque(observer).takeUnretainedValue().continuation.yield()
            }, changedName as CFString, nil, .deliverImmediately)
            continuation.onTermination = { _ in
                CFNotificationCenterRemoveObserver(center, box, CFNotificationName(changedName as CFString), nil)
                Unmanaged<ContinuationBox>.fromOpaque(box).release()
            }
        }
    }

    private final class ContinuationBox: @unchecked Sendable {
        let continuation: AsyncStream<Void>.Continuation
        init(_ continuation: AsyncStream<Void>.Continuation) { self.continuation = continuation }
    }

    /// Button-only sites as last edited in the app, with when (ms since 1970).
    /// The extension takes them when they're newer than its own copy.
    static func loadManual() -> (sites: [String: Bool], at: Double)? {
        guard let stored = defaults?.dictionary(forKey: manualKey),
              let sites = stored["manual"] as? [String: Bool],
              let at = stored["manualAt"] as? Double else { return nil }
        return (sites, at)
    }

    static func saveManual(_ sites: [String: Bool]) {
        defaults?.set(["manual": sites, "manualAt": Date().timeIntervalSince1970 * 1000], forKey: manualKey)
    }

    static func load() -> ExtensionStatus? {
        guard let data = defaults?.data(forKey: statusKey) else { return nil }
        return try? JSONDecoder().decode(ExtensionStatus.self, from: data)
    }
}
