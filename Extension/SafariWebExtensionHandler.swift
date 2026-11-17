import SafariServices
import os
#if os(macOS)
import AppKit
#endif

/// Native side of the Safari extension. Looks up articles from the extension's
/// own process (see OWLResolver), stores the settings background.js reports for
/// the app to show, and on the Mac opens articles in News without Safari's
/// "Open in News?" prompt.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private static let log = Logger(subsystem: "com.canopysf.AutoOpenInNews", category: "lookup")

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any] ?? [:]

        switch message["action"] as? String {
        case "resolve":
            let url = message["url"] as? String ?? ""
            Task {
                do {
                    #if DEBUG
                    let started = ContinuousClock.now
                    #endif
                    let result = try await OWLResolver.resolve(url)
                    #if DEBUG
                    let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
                    Self.log.debug("Lookup \(result.articleID != nil ? "found" : "missed", privacy: .public) in \(ms) ms, \(result.ranged ? "partial" : "whole", privacy: .public) index download\(OWLResolver.sendsNewsHeaders ? " as News" : "", privacy: .public)")
                    #endif
                    Self.reply(context, ["found": result.articleID != nil, "id": result.articleID ?? ""])
                } catch {
                    Self.reply(context, ["error": String(describing: error)])
                }
            }
        case "sync":
            if let state = message["state"] {
                SharedStatus.save(state)
            }
            Self.reply(context, Self.appManual())
        case "pull":
            Self.reply(context, Self.appManual())
        case "open":
            Self.reply(context, ["opened": open(articleID: message["id"] as? String)])
        default:
            Self.reply(context, [:])
        }
    }

    /// The app's button-only sites; background.js keeps them if they're newer.
    private static func appManual() -> [String: Any] {
        guard let manual = SharedStatus.loadManual() else { return [:] }
        return ["manual": manual.sites, "manualAt": manual.at]
    }

    private static func reply(_ context: NSExtensionContext, _ message: [String: Any]) {
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: message]
        context.completeRequest(returningItems: [response])
    }

    private func open(articleID: String?) -> Bool {
        #if os(macOS)
        guard let id = articleID,
              id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
              let url = URL(string: "applenewss:///\(id)") else { return false }
        return NSWorkspace.shared.open(url)
        #else
        return false // iOS extensions can't open URLs; the page does it instead
        #endif
    }
}
