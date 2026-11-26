import AppKit
import SwiftUI

/// Mac Care → Uninstaller: every removable app with its size and support files, plus leftovers of apps already gone.
struct UninstallerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = UninstallerModel()

    private var query: String { appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Group {
                switch model.segment {
                case .apps: UninstallerAppsPane(model: model, query: query)
                case .leftovers: UninstallerLeftoversPane(model: model, query: query)
                }
            }
            .transition(.opacity)
        }
        .animation(.adaptive(reduceMotion, Tokens.quick), value: model.segment)
        .task { model.start() }
        .onDisappear { model.stop() }
        .sheet(item: $model.flow) { flow in
            UninstallerFlowSheet(model: model, flow: flow)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Uninstaller")
                    .font(.system(size: 22, weight: .semibold))
                Text(summary)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer()
            Picker("View", selection: segmentBinding) {
                ForEach(UninstallerModel.Segment.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Installed apps, or files left behind by apps you already removed")
            Button {
                model.segment == .apps ? model.rescan() : model.scanLeftovers()
            } label: {
                Label("Scan Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.glass)
            .disabled(model.phase == .scanning || model.leftoverPhase == .scanning)
            .help(model.segment == .apps ? "Look for apps again" : "Look for leftovers again")
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var segmentBinding: Binding<UninstallerModel.Segment> {
        Binding(get: { model.segment }, set: { value in
            guard value != model.segment else { return }
            model.segment = value
            if value == .leftovers, model.leftoverPhase == .idle, model.phase == .ready { model.scanLeftovers() }
        })
    }

    private var summary: String {
        switch model.segment {
        case .apps:
            if model.phase == .scanning, model.apps.isEmpty { return "Looking for apps…" }
            let count = model.apps.count
            let base = "\(count) app\(count == 1 ? "" : "s")"
            if model.isMeasuring { return "\(base) · measuring \(model.measuredCount) of \(count)" }
            return "\(base) · \(Format.bytes(model.totalMeasured)) in total"
        case .leftovers:
            switch model.leftoverPhase {
            case .idle, .scanning: return "Looking for files left behind…"
            case .ready:
                let groups = model.leftoverGroups.count
                return groups == 0 ? "Nothing left behind"
                    : "\(groups) removed app\(groups == 1 ? "" : "s") left \(Format.bytes(model.leftoverTotal))"
            }
        }
    }
}

/// Small helpers shared by the Uninstaller views.
@MainActor
enum UninstallerUI {
    private static var iconCache: [String: NSImage] = [:]

    static func icon(_ path: String) -> NSImage {
        if let cached = iconCache[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        iconCache[path] = image
        return image
    }

    static func reveal(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        FinderReveal.reveal(urls)
    }

    static func lastOpened(_ date: Date?) -> String {
        guard let date else { return "Last opened unknown" }
        if Calendar.current.isDateInToday(date) { return "Opened today" }
        return "Opened " + date.formatted(.relative(presentation: .named))
    }

    /// "on External" / "link" notes for the subtitle.
    static func linkNote(_ link: UninstallLinkTarget) -> String? {
        switch link {
        case .none: nil
        case .supportTarget: UninstallLinks.volumeNote(link)
        case .broken: "link to a missing item"
        case .unexpected: "link to another location"
        }
    }

    /// Replaces the size for links whose target isn't measured.
    static func linkSizeLabel(_ link: UninstallLinkTarget) -> String? {
        switch link {
        case .broken: "Broken link"
        case .unexpected: "Link"
        case .none, .supportTarget: nil
        }
    }

    static func linkHelp(_ link: UninstallLinkTarget) -> String {
        switch link {
        case .none: ""
        case .supportTarget(let target): "The data lives at \(target.path). Both the data and the link go to the Trash."
        case .broken: "The link points at something that no longer exists. Only the link goes to the Trash."
        case .unexpected(let target): "Points to \(target.path), outside a Library support folder. Only the link is removed; the target is left alone."
        }
    }

    static func size(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return bytes == 0 ? "Zero KB" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// A row-shaped capsule label (location, App Store, Running).
struct UninstallerBadge: View {
    let text: String
    var symbol: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.12), in: .capsule)
        .fixedSize()
    }
}
