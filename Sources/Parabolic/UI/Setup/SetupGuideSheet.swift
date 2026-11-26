import AppKit
import SwiftUI

/// "Set Up Root": every permission and catching check in one place, each with a live status and the one
/// button that fixes it. Statuses re-read every 2 seconds while open, so flipping a switch in System Settings
/// shows up here on its own.
struct SetupGuideSheet: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var browsers: [BrowserStatus] = []
    @State private var ownsMagnet = false
    @State private var ownsTorrent = false
    @State private var magnetOwner: String?
    @State private var claimError: String?
    @State private var copied: String?

    private var center: PermissionCenter { .shared }
    private var folder: String { settings.prefs.downloadFolder }
    private static let extensionsPage = "chrome://extensions"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Tokens.space5)
                .padding(.top, Tokens.space5)
                .padding(.bottom, Tokens.space4)
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.space5) {
                    SetupGroup(title: "Permissions") {
                        ForEach(RootPermission.allCases) { permission in
                            permissionRow(permission)
                        }
                    }
                    SetupGroup(title: "Download catching") {
                        catchingRows
                    }
                }
                .padding(.horizontal, Tokens.space5)
                .padding(.bottom, Tokens.space4)
            }
            .scrollBounceBehavior(.basedOnSize)
            Divider()
            footer
                .padding(.horizontal, Tokens.space5)
                .padding(.vertical, Tokens.space3)
        }
        .frame(width: 600, height: 640)
        .task { await poll() }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(alignment: .top, spacing: Tokens.space3) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 52, height: 52)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Set Up Root")
                    .font(.system(size: 20, weight: .bold))
                Text(summary)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var summary: String {
        let missing = center.missing.count + catchingProblems
        if center.statuses.isEmpty { return "Checking what Root can do on this Mac…" }
        if missing == 0 { return "Everything is set. Root keeps these permissions across updates." }
        return missing == 1 ? "1 thing still needs your OK. Each button opens the right place."
                            : "\(missing) things still need your OK. Each button opens the right place."
    }

    /// Chromium browsers where Root's extension or a rival's is present; all of them when neither is anywhere.
    private var relevantBrowsers: [BrowserStatus] {
        let chromium = browsers.filter { !$0.browser.isFirefox }
        let involved = chromium.filter { ($0.rootExtension ?? .notInstalled) != .notInstalled || !$0.rivals.isEmpty }
        return involved.isEmpty ? chromium : involved
    }

    private var catchingProblems: Int {
        let chromium = relevantBrowsers
        let missingExtension = chromium.contains { $0.rootExtension == .enabled } ? 0 : (chromium.isEmpty ? 0 : 1)
        let rivals = chromium.filter { !$0.rivals.isEmpty }.count
        return missingExtension + rivals + (ownsMagnet && ownsTorrent ? 0 : 1)
    }

    private var footer: some View {
        HStack {
            if let copied {
                Label("Copied \(copied)", systemImage: "checkmark")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            Spacer()
            Button("Done") {
                settings.prefs.setupGuideVersion = SetupGuide.currentVersion
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
        }
    }

    // MARK: Permissions

    private func permissionRow(_ permission: RootPermission) -> some View {
        let status = center.status(permission)
        let tone = permission.isOptional && status != .granted ? SetupTone.neutral : SetupTone(status)
        return SetupRow(symbol: permission.symbol, title: permission.title, detail: permission.reason, tone: tone) {
            SetupStatusLabel(text: status.label, tone: tone)
            if status != .granted {
                if permission == .fullDiskAccess {
                    Button("Show App") { center.revealApp() }
                        .help("Shows Root.app in Finder so you can drag it into the Full Disk Access list.")
                }
                Button(permission.canPrompt && status == .notAsked ? "Allow…" : "Open Settings") {
                    Task { await center.request(permission, downloadFolder: folder) }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("\(permission.canPrompt && status == .notAsked ? "Allow" : "Open Settings for") \(permission.title)")
            }
        }
    }

    // MARK: Catching

    @ViewBuilder private var catchingRows: some View {
        ForEach(relevantBrowsers) { status in
            extensionRow(status)
            ForEach(status.rivals, id: \.self) { rival in
                rivalRow(rival, in: status.browser.name)
            }
        }
        if browsers.allSatisfy({ $0.browser.isFirefox }) {
            SetupRow(symbol: "globe", title: "Browser extension", detail: "No Chromium browser found on this Mac.", tone: .neutral) {}
        }
        SetupRow(symbol: "link", title: "Magnet links and .torrent files",
                 detail: ownsMagnet && ownsTorrent ? "Open in Root."
                    : "Open in \(magnetOwner ?? "another app") now.",
                 tone: ownsMagnet && ownsTorrent ? .good : .warning) {
            SetupStatusLabel(text: ownsMagnet && ownsTorrent ? "Root" : "Not Root", tone: ownsMagnet && ownsTorrent ? .good : .warning)
            if !(ownsMagnet && ownsTorrent) {
                Button("Use Root") {
                    Task {
                        settings.prefs.isDefaultDownloadManager = true
                        claimError = await DefaultDownloadManager.claim()
                        readHandlers()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        if let claimError {
            Text(claimError).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func extensionRow(_ status: BrowserStatus) -> some View {
        let state = status.rootExtension ?? .notInstalled
        let tone: SetupTone = state == .enabled ? (status.isConnected ? .good : .warning) : .bad
        let detail: String = switch state {
        case .enabled: status.isConnected ? "Catches downloads and hands them to Root." : "Installed, but the helper isn’t connected."
        case .disabled: "Installed but turned off. Turn it on in \(Self.extensionsPage)."
        case .notInstalled: "Not installed. Load unpacked → pick the folder Root shows you."
        }
        return SetupRow(symbol: "puzzlepiece.extension", title: "Root extension in \(status.browser.name)", detail: detail, tone: tone) {
            SetupStatusLabel(text: state == .enabled ? "On" : (state == .disabled ? "Off" : "Missing"), tone: tone)
            if state != .enabled {
                Button("Install…") { installHelp() }
                    .buttonStyle(.borderedProminent)
                    .help("Shows the extension folder in Finder and copies \(Self.extensionsPage).")
            } else if !status.isConnected {
                Button("Connect") {
                    BrowserBridge.installHosts()
                    Task { await readBrowsers() }
                }
            }
        }
    }

    private func rivalRow(_ rival: String, in browser: String) -> some View {
        SetupRow(symbol: "exclamationmark.triangle", title: "\(rival) is also catching in \(browser)",
                 detail: "Its extension takes downloads before Root. Turn it off in \(browser)’s extensions page, or click “Turn It Off” in Root’s extension menu.",
                 tone: .warning) {
            Button("Copy Address") { copy(Self.extensionsPage) }
        }
    }

    // MARK: Actions

    private func installHelp() {
        ExtensionInstaller.installFromBundleOrLog()
        FinderReveal.reveal([ExtensionInstaller.chromiumFolder])
        copy(Self.extensionsPage)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(Tokens.quick) { copied = text }
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation(Tokens.quick) { copied = nil }
        }
    }

    private func poll() async {
        while !Task.isCancelled {
            await center.refresh(downloadFolder: folder)
            await readBrowsers()
            readHandlers()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func readBrowsers() async {
        let next = await Task.detached(priority: .utility) { BrowserStatus.readAll() }.value
        browsers = next
    }

    private func readHandlers() {
        ownsMagnet = DefaultDownloadManager.ownsMagnetLinks
        ownsTorrent = DefaultDownloadManager.ownsTorrentFiles
        magnetOwner = DefaultDownloadManager.ownsMagnetLinks
            ? DefaultDownloadManager.name(of: DefaultDownloadManager.torrentHandler)
            : DefaultDownloadManager.name(of: DefaultDownloadManager.magnetHandler)
    }
}

/// When the setup guide shows by itself.
@MainActor
enum SetupGuide {
    /// Bump to show the guide once more after an update that adds a permission or check.
    static let currentVersion = 1

    /// True when a permission is missing, no browser has Root's extension on, a rival catcher is on,
    /// or another app opens magnet links. The guide only shows by itself when this is true.
    static func needsAttention(downloadFolder: String) async -> Bool {
        let center = PermissionCenter.shared
        await center.refresh(downloadFolder: downloadFolder)
        if !center.missing.isEmpty { return true }
        let browsers = await Task.detached(priority: .utility) { BrowserStatus.readAll() }.value
        let chromium = browsers.filter { !$0.browser.isFirefox }
        if !chromium.isEmpty, !chromium.contains(where: { $0.rootExtension == .enabled }) { return true }
        if chromium.contains(where: { !$0.rivals.isEmpty }) { return true }
        return !DefaultDownloadManager.isDefault
    }
}

// MARK: - Building blocks

enum SetupTone {
    case good, warning, bad, neutral

    init(_ status: PermissionStatus) {
        switch status {
        case .granted: self = .good
        case .denied: self = .bad
        case .notAsked: self = .warning
        }
    }

    /// Status dot colour. No orange anywhere in Root (owner's call): warnings use the system yellow.
    var color: Color {
        switch self {
        case .good: .green
        case .warning: .yellow
        case .bad: .red
        case .neutral: .secondary
        }
    }

    /// Icon tile tint: yellow symbols are unreadable on light backgrounds, so warnings stay neutral there.
    var tileColor: Color {
        switch self {
        case .good: .green
        case .bad: .red
        case .warning, .neutral: .secondary
        }
    }
}

private struct SetupGroup<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.space2) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { Divider().padding(.leading, 52) }
                        row
                    }
                }
            }
            .background(.background.secondary, in: .rect(cornerRadius: Tokens.radiusRow))
            .overlay(RoundedRectangle(cornerRadius: Tokens.radiusRow).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
        }
    }
}

private struct SetupRow<Actions: View>: View {
    var symbol: String
    var title: String
    var detail: String
    var tone: SetupTone
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: Tokens.space3) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tone.tileColor)
                .frame(width: 30, height: 30)
                .background(tone.tileColor.opacity(0.13), in: .rect(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: Tokens.space2) { actions }
                .controlSize(.small)
                .fixedSize()
        }
        .padding(.horizontal, Tokens.space3)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }
}

private struct SetupStatusLabel: View {
    var text: String
    var tone: SetupTone

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tone.color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 11.5, weight: .medium)).foregroundStyle(tone == .bad ? Color.red : .primary)
        }
        .accessibilityElement(children: .combine)
    }
}
