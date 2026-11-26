import AppKit
import SwiftUI

/// Every action a download row, context menu or keyboard shortcut can run, for one or many items.
@MainActor
struct DownloadActions {
    let manager: DownloadManager
    let appState: AppState
    var conversions: ConversionStore?

    func items(_ ids: Set<UUID>) -> [DownloadItem] { manager.items(ids) }

    // MARK: Convert & navigate

    /// Starts an ffmpeg conversion for every finished file in `items`.
    func convert(_ items: [DownloadItem], to target: ConversionTarget) {
        guard let conversions else { return }
        for item in items {
            guard let url = item.completedFileURL else { continue }
            if conversions.convert(url, to: target, duration: item.meta.duration) == nil { NSSound.beep() }
        }
    }

    func showPlatform(_ platform: Platform) {
        appState.sidebarSelection = .platform(platform)
    }

    func downloadAgainWithOptions(_ item: DownloadItem) {
        appState.presentAdd(url: item.sourceURL)
    }

    // MARK: Files

    func open(_ items: [DownloadItem]) {
        for url in items.compactMap(\.completedFileURL) { NSWorkspace.shared.open(url) }
    }

    /// Selects the files in Finder (following moved/renamed files); falls back to the save folder.
    func reveal(_ items: [DownloadItem]) {
        FinderReveal.reveal(paths: items.map(\.filePath), fallbackFolder: items.first?.options.saveFolder)
    }

    func copyLinks(_ items: [DownloadItem]) { LinkText.copy(items.map(\.sourceURL)) }

    func openSourcePages(_ items: [DownloadItem]) {
        for url in items.compactMap({ URL(string: $0.sourceURL) }) { NSWorkspace.shared.open(url) }
    }

    // MARK: Lifecycle

    func pause(_ items: [DownloadItem]) {
        for item in items where item.canPause { manager.pause(item) }
    }

    func resume(_ items: [DownloadItem]) {
        for item in items where item.canResume { manager.resume(item) }
    }

    func stop(_ items: [DownloadItem]) {
        for item in items where item.canStop { manager.stop(item) }
    }

    func retry(_ items: [DownloadItem]) {
        for item in items where item.canRetry { manager.retry(item) }
    }

    func startNow(_ items: [DownloadItem]) {
        for item in items where item.status == .queued || item.status == .scheduled { manager.startNow(item) }
    }

    func remove(_ items: [DownloadItem], trashingFiles: Bool = false) {
        let ids = Set(items.map(\.id))
        for item in items { manager.remove(item, deleteFile: trashingFiles) }
        appState.selectedItemIDs.subtract(ids)
    }
}

/// Right-click menu for one or several selected downloads.
struct DownloadContextMenu: View {
    let items: [DownloadItem]
    let actions: DownloadActions
    var onQuickLook: (URL) -> Void

    var body: some View {
        if !items.isEmpty {
            let files = items.compactMap(\.completedFileURL)
            Button { actions.open(items) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
                .disabled(files.isEmpty)
            Button { actions.reveal(items) } label: { Label("Show in Finder", systemImage: "folder") }
            Button {
                if let first = files.first { onQuickLook(first) }
            } label: { Label("Quick Look", systemImage: "eye") }
                .disabled(files.isEmpty)

            Divider()
            Button { actions.copyLinks(items) } label: {
                Label(items.count > 1 ? "Copy Links" : "Copy Link", systemImage: "link")
            }
            Button { actions.openSourcePages(items) } label: { Label("Open Source Page", systemImage: "safari") }
            if let platform = sharedPlatform {
                Button { actions.showPlatform(platform) } label: {
                    Label { Text("Show \(platform.title)") } icon: { PlatformMenuIcon.image(platform) }
                }
            }

            Divider()
            convertMenu(enabled: !files.isEmpty)
            if items.count == 1, let item = items.first {
                Button { actions.downloadAgainWithOptions(item) } label: {
                    Label("Download Again with Options…", systemImage: "arrow.down.circle")
                }
            }

            if items.contains(where: { !$0.status.isFinished || $0.status == .stopped }) {
                speedMenu
            }

            Divider()
            lifecycleButtons

            Divider()
            Button(role: .destructive) { actions.remove(items) } label: { Label("Remove", systemImage: "minus.circle") }
            Button(role: .destructive) { actions.remove(items, trashingFiles: true) } label: {
                Label("Move File to Trash & Remove", systemImage: "trash")
            }
            .disabled(!items.contains(where: \.fileExists))
        }
    }

    /// Per-download speed cap. Running downloads restart (and resume) to apply it.
    private var speedMenu: some View {
        let current = Set(items.map(\.options.speedLimitKBps))
        let choices: [(String, Int?)] = [("Follow Global Limit", nil), ("Unlimited", 0), ("100 KB/s", 100),
                                         ("500 KB/s", 500), ("1 MB/s", 1024), ("5 MB/s", 5120), ("10 MB/s", 10240)]
        return Menu {
            ForEach(choices, id: \.0) { title, value in
                Button {
                    items.forEach { actions.manager.setSpeedLimit($0, kbps: value) }
                } label: {
                    if current == [value] { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
        } label: {
            Label("Speed Limit", systemImage: "speedometer")
        }
    }

    /// The one platform every selected item comes from, if they agree.
    private var sharedPlatform: Platform? {
        let platforms = Set(items.map(\.platform))
        guard platforms.count == 1, let only = platforms.first, only != .other else { return nil }
        return only
    }

    private func convertMenu(enabled: Bool) -> some View {
        Menu {
            ForEach(ConversionTarget.allCases) { target in
                Button { actions.convert(items, to: target) } label: { Label(target.label, systemImage: target.symbol) }
            }
        } label: {
            Label("Convert To", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(!enabled || actions.conversions == nil)
    }

    @ViewBuilder private var lifecycleButtons: some View {
        if items.contains(where: \.canPause) {
            Button { actions.pause(items) } label: { Label("Pause", systemImage: "pause") }
        }
        if items.contains(where: \.canResume) {
            Button { actions.resume(items) } label: { Label("Resume", systemImage: "play") }
        }
        if items.contains(where: { $0.status == .queued || $0.status == .scheduled }) {
            Button { actions.startNow(items) } label: { Label("Start Now", systemImage: "bolt") }
        }
        if items.contains(where: \.canStop) {
            Button { actions.stop(items) } label: { Label("Stop", systemImage: "stop") }
        }
        if items.contains(where: \.canRetry) {
            Button { actions.retry(items) } label: { Label("Retry", systemImage: "arrow.clockwise") }
        }
    }
}

/// Glass circular buttons revealed when hovering a row.
struct DownloadRowActions: View {
    let item: DownloadItem
    let actions: DownloadActions

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                primaryControl
                secondaryControl
                if item.fileExists || item.status == .completed {
                    CircleGlassButton(title: "Show in Finder", symbol: "magnifyingglass") { actions.reveal([item]) }
                }
                CircleGlassButton(title: "Remove", symbol: "xmark") { actions.remove([item]) }
            }
        }
    }

    @ViewBuilder private var primaryControl: some View {
        if item.canPause {
            CircleGlassButton(title: "Pause", symbol: "pause.fill") { actions.pause([item]) }
        } else if item.canResume {
            CircleGlassButton(title: "Resume", symbol: "play.fill", tint: .parabolicAccent) { actions.resume([item]) }
        } else if item.status == .queued || item.status == .scheduled {
            CircleGlassButton(title: "Start Now", symbol: "bolt.fill", tint: .parabolicAccent) { actions.startNow([item]) }
        }
    }

    @ViewBuilder private var secondaryControl: some View {
        if item.canStop {
            CircleGlassButton(title: "Stop", symbol: "stop.fill") { actions.stop([item]) }
        } else if item.canRetry {
            CircleGlassButton(title: "Retry", symbol: "arrow.clockwise", tint: .parabolicAccent) { actions.retry([item]) }
        }
    }
}
