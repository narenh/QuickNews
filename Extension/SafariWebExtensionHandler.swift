import SafariServices
import os
#if os(macOS)
import AppKit
#endif

/// Native side of the Safari extension. Looks up articles from the extension's
/// own process (see OWLResolver), reads and writes the site settings the app
/// shares (SharedStatus), stores what background.js reports for the app to show,
/// and on the Mac opens articles in News without Safari's "Open in News?" prompt.
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
            Self.reply(context, [:])
        case "settings":
            // stored: false tells background.js to hand over settings from an older build.
            if let modes = SharedStatus.storedModes() {
                Self.reply(context, ["modes": modes.mapValues(\.rawValue)])
            } else {
                Self.reply(context, ["stored": false])
            }
        case "setModes":
            let raw = message["modes"] as? [String: String] ?? [:]
            if SharedStatus.storedModes() == nil {
                SharedStatus.saveModes(raw.compactMapValues(SiteMode.init(rawValue:)))
            }
            Self.reply(context, ["modes": SharedStatus.modes.mapValues(\.rawValue)])
        case "setMode":
            var modes = SharedStatus.modes
            if let site = message["site"] as? String, let mode = (message["mode"] as? String).flatMap(SiteMode.init(rawValue:)) {
                modes[site] = mode
                SharedStatus.saveModes(modes)
            }
            Self.reply(context, [:])
        case "open":
            Self.reply(context, ["opened": open(articleID: message["id"] as? String)])
        case "openApp":
            Self.reply(context, ["opened": openApp()])
        default:
            Self.reply(context, [:])
        }
    }

    private static func reply(_ context: NSExtensionContext, _ message: [String: Any]) {
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: message]
        context.completeRequest(returningItems: [response])
    }

    /// Opens the app this extension ships in. The extension sits in
    /// QuickNews.app/Contents/PlugIns/, so the app is two folders up.
    private func openApp() -> Bool {
        #if os(macOS)
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        return true
        #else
        return false // iOS extensions can't open apps; the popup asks Safari to
        #endif
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
