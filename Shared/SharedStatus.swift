import Foundation

/// What the extension last reported about itself (where it ran, its website
/// access), shared with the app through the app group. The site settings
/// aren't part of it: they live in the app group itself (`SharedStatus.modes`).
struct ExtensionStatus: Codable {
    var seen: [String: Double]  // site -> when the extension last ran there (ms since 1970)
    var active: Double          // when the extension last ran anywhere (ms since 1970)
    var access: String?          // websites Safari lets it run on: "all", "some" or "none"

    /// When the extension last ran anywhere.
    var lastActive: Date? { active > 0 ? Date(timeIntervalSince1970: active / 1000) : nil }

    func lastSeen(_ site: String) -> Date? {
        seen[site].map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}

/// What the extension does on a site. A site that isn't in the map is off.
enum SiteMode: String, CaseIterable, Identifiable {
    case off, ask, auto

    var id: Self { self }
    var title: String { rawValue.capitalized }
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
    private static let modesKey = "siteModes"

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

    /// Posted across processes whenever the extension's report or the site settings change.
    private static let changedName = "com.canopysf.AutoOpenInNews.statusChanged"

    /// Yields each time the report or the site settings change, so the app can update while it's open.
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

    /// The site settings: the one copy, which the app and the extension both
    /// read and write. nil until either has saved them.
    static func storedModes() -> [String: SiteMode]? {
        guard let raw = defaults?.dictionary(forKey: modesKey)?["modes"] as? [String: String] else { return nil }
        return raw.compactMapValues(SiteMode.init(rawValue:))
    }

    /// The site settings, or before anything is saved, the defaults: every built-in site on Auto.
    static var modes: [String: SiteMode] {
        storedModes() ?? Dictionary(uniqueKeysWithValues: seedSites.map { ($0, SiteMode.auto) })
    }

    static func saveModes(_ modes: [String: SiteMode]) {
        defaults?.set(["modes": modes.mapValues(\.rawValue)], forKey: modesKey)
        postChanged()
    }

    static func load() -> ExtensionStatus? {
        guard let data = defaults?.data(forKey: statusKey) else { return nil }
        return try? JSONDecoder().decode(ExtensionStatus.self, from: data)
    }
}
