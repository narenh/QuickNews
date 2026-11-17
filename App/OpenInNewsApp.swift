import SafariServices
import SwiftUI
import os

private let log = Logger(subsystem: "com.canopysf.AutoOpenInNews", category: "status")

@main
struct OpenInNewsApp: App {
    var body: some Scene {
        WindowGroup {
            StatusView()
            #if os(macOS)
                .frame(minWidth: 440, idealWidth: 480, minHeight: 520, idealHeight: 640)
            #endif
        }
        #if os(macOS)
        .windowResizability(.contentSize)
        #endif
    }
}

// MARK: - Model

@Observable
final class StatusModel {
    /// nil when iOS can't say: before iOS 26.2, or when the check failed.
    var extensionEnabled: Bool?
    var status: ExtensionStatus?
    /// Bumped when the app edits the site modes, so views that read them update.
    var modesRevision = 0

    func refresh() async {
        #if os(macOS)
        extensionEnabled = try? await SFSafariExtensionManager.stateOfSafariExtension(withIdentifier: SharedStatus.extensionID).isEnabled
        #else
        if #available(iOS 26.2, *) {
            // The check has been seen to fail now and then, so it gets a second try.
            extensionEnabled = nil
            for attempt in 0..<2 where extensionEnabled == nil {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(500)) }
                do {
                    extensionEnabled = try await SFSafariExtensionManager.stateOfExtension(withIdentifier: SharedStatus.extensionID).isEnabled
                } catch {
                    log.error("Extension state check failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
        #endif
        status = SharedStatus.load()
        modesRevision += 1
    }
}

// MARK: - Lights

enum Light {
    case green, yellow, red, off

    var color: Color {
        switch self {
        case .green: .green
        case .yellow: .yellow
        case .red: .red
        case .off: .gray.opacity(0.45)
        }
    }
}

struct StatusLight: View {
    let light: Light

    var body: some View {
        Circle()
            .fill(light.color.gradient)
            .frame(width: 14, height: 14)
            .shadow(color: light == .off ? .clear : light.color.opacity(0.7), radius: 5)
    }
}

struct StatusRow<Detail: View>: View {
    let light: Light
    let title: String
    @ViewBuilder let detail: Detail

    var body: some View {
        HStack(spacing: 14) {
            StatusLight(light: light)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                detail
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Screen

struct StatusView: View {
    @State private var model = StatusModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    extensionRow
                    if SharedStatus.isAvailable {
                        accessRow
                    }
                    Button("Open Safari Extension Settings") {
                        openExtensionSettings()
                    }
                } footer: {
                    if !SharedStatus.isAvailable {
                        Text("This build was signed without its app group, so it can’t show the extension’s settings.")
                    }
                }
                if SharedStatus.isAvailable {
                    sitesLink
                }
                setupSection
            }
            .formStyle(.grouped)
            .navigationTitle("QuickNews")
            .refreshable { await model.refresh() }
        }
        .task {
            for await _ in SharedStatus.changes() { await model.refresh() }
        }
        .task(id: scenePhase) {
            if scenePhase == .active { await model.refresh() }
        }
    }

    @ViewBuilder
    private var extensionRow: some View {
        let light: Light = switch extensionOn { case true?: .green; case false?: .red; case nil: .off }
        StatusRow(light: light, title: "Safari Extension") {
            Text(extensionOn.map { $0 ? "On" : "Off" } ?? "Unknown")
        }
    }

    /// Whether Safari lets the extension run on every website, which is what
    /// makes it work on any site you add. As last reported by the extension.
    @ViewBuilder
    private var accessRow: some View {
        let (light, detail): (Light, LocalizedStringKey) = switch model.status?.access {
        case "all"?: (.green, "Granted")
        case "some"?: (.yellow, "Some Websites")
        case "none"?: (.red, "Not Granted")
        default: (.off, "Unknown")
        }
        StatusRow(light: light, title: "Website Access") { Text(detail) }
    }

    /// iOS's answer, or, when it can't give one, On if the extension ran in the last day.
    private var extensionOn: Bool? {
        if let enabled = model.extensionEnabled { return enabled }
        if let active = model.status?.lastActive, -active.timeIntervalSinceNow < 24 * 3600 { return true }
        return nil
    }

    /// Opens Safari's settings at this extension: on/off, and its website access.
    private func openExtensionSettings() {
        #if os(macOS)
        SFSafariApplication.showPreferencesForExtension(withIdentifier: SharedStatus.extensionID)
        #else
        if #available(iOS 26.2, *) {
            SFSafariSettings.openExtensionsSettings(forIdentifiers: [SharedStatus.extensionID])
        } else if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }

    private var sitesLink: some View {
        Section {
            NavigationLink {
                SitesView(model: model)
            } label: {
                LabeledContent("Sites", value: model.summary)
            }
        }
    }

    private var setupSteps: [String] {
        #if os(macOS)
        ["Click Open Safari Extension Settings above",
         "Tick QuickNews",
         "Click Edit Websites… and set Other Websites to Allow"]
        #else
        ["Tap Open Safari Extension Settings above",
         "Turn on Allow Extension",
         "Set Other Websites to Allow"]
        #endif
    }

    private var setupSection: some View {
        Section {
            ForEach(Array(setupSteps.enumerated()), id: \.offset) { index, step in
                Label(step, systemImage: "\(index + 1).circle")
            }
        } header: {
            Text("Set up")
        } footer: {
            Text("Article lookups occur on-device and are not logged or transmitted anywhere.")
        }
    }
}
