import SwiftUI

/// The site list the extension works from: the built-in sites plus any you add.
/// A site missing from the modes is off.
extension StatusModel {
    /// The site settings, shared with the extension.
    var modes: [String: SiteMode] {
        _ = modesRevision // the settings live in storage; reading this keeps views watching them
        return SharedStatus.modes
    }

    func mode(_ site: String) -> SiteMode { modes[site] ?? .off }

    /// Sites you added: in the modes but not built in.
    var customSites: [String] { modes.keys.filter { !seedSites.contains($0) }.sorted() }

    /// Built-in sites and the ones you added, alphabetically.
    var allSites: [String] { Set(seedSites).union(customSites).sorted() }

    /// Sites the extension has run on, newest first.
    var visitedSites: [String] {
        let known = Set(allSites)
        return (status?.seen ?? [:]).filter { known.contains($0.key) }.sorted { $0.value > $1.value }.map(\.key)
    }

    var summary: String {
        let counts = allSites.reduce(into: [SiteMode: Int]()) { $0[mode($1), default: 0] += 1 }
        let parts = [SiteMode.auto, .ask].compactMap { mode in counts[mode].map { "\($0) \(mode.title)" } }
        return parts.isEmpty ? "All Off" : parts.joined(separator: ", ")
    }

    func set(_ site: String, _ mode: SiteMode) {
        var next = modes
        next[site] = mode
        write(next)
    }

    func setAll(_ sites: [String], to mode: SiteMode) {
        var next = modes
        for site in sites { next[site] = mode }
        write(next)
    }

    func remove(_ site: String) {
        guard !seedSites.contains(site) else { return }
        var next = modes
        next[site] = nil
        write(next)
    }

    private func write(_ modes: [String: SiteMode]) {
        SharedStatus.saveModes(modes)
        modesRevision += 1 // modes is computed from storage; this makes views read it again
    }

    /// A pasted URL or host as a bare lowercase host without "www.", or nil if it isn't one.
    static func site(from text: String) -> String? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        text = String(text.prefix { !"/?#".contains($0) })
        if let at = text.lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }
        text = String(text.prefix { $0 != ":" })
        if text.hasPrefix("www.") { text = String(text.dropFirst(4)) }
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        let valid = labels.count >= 2 && labels.allSatisfy { label in
            !label.isEmpty && !label.hasPrefix("-") && !label.hasSuffix("-") && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
        return valid ? text : nil
    }

    func add(_ text: String) -> Bool {
        guard let site = Self.site(from: text) else { return false }
        var next = modes
        next[site] = .auto
        write(next)
        return true
    }
}

struct SitesView: View {
    let model: StatusModel
    @State private var newSite = ""

    var body: some View {
        List {
            if !SharedStatus.isAvailable {
                Section {
                    Text("This build was signed without its app group, so it can’t edit the extension’s sites.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    HStack {
                        TextField("Add site", text: $newSite, prompt: Text("example.com"))
                            .autocorrectionDisabled()
                        #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                        #endif
                            .onSubmit(add)
                        Button("Add", action: add)
                            .disabled(StatusModel.site(from: newSite) == nil)
                    }
                }
                if !model.visitedSites.isEmpty {
                    Section {
                        ForEach(model.visitedSites, id: \.self) { row($0, showSeen: true) }
                    } header: {
                        header("Visited", sites: model.visitedSites)
                    }
                }
                Section {
                    ForEach(model.allSites, id: \.self) { row($0, showSeen: false) }
                } header: {
                    header("All sites", sites: model.allSites)
                } footer: {
                    Text("Off: not checked. Ask: shows the Open in News button, never opens News by itself. Auto: opens News by itself.")
                }
            }
        }
        .navigationTitle("Sites")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .refreshable { await model.refresh() }
    }

    private func add() {
        if model.add(newSite) { newSite = "" }
    }

    /// A section title with a "Set All…" menu that sets every site in the section.
    private func header(_ title: String, sites: [String]) -> some View {
        HStack {
            Text(title)
            Spacer()
            Menu("Set All…") {
                ForEach([SiteMode.auto, .ask, .off]) { mode in
                    Button(mode.title) { model.setAll(sites, to: mode) }
                }
            }
            .font(.subheadline)
            .textCase(nil)
        }
    }

    private func row(_ site: String, showSeen: Bool) -> some View {
        let custom = !seedSites.contains(site)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(site)
                Spacer()
                if showSeen, let seen = model.status?.lastSeen(site) {
                    Text(seen, format: .relative(presentation: .named))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Picker(site, selection: Binding(get: { model.mode(site) }, set: { model.set(site, $0) })) {
                ForEach(SiteMode.allCases) { Text($0.title) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .font(.footnote)
        }
        .padding(.vertical, 2)
        .swipeActions {
            if custom {
                Button("Delete", role: .destructive) { model.remove(site) }
            }
        }
        .contextMenu {
            if custom {
                Button("Delete", role: .destructive) { model.remove(site) }
            }
        }
    }
}
