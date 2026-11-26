import AppKit
import SwiftUI

@main
struct ParabolicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var services = Services.shared

    var body: some Scene {
        Window("Root", id: "main") {
            MainWindowView()
                .windowGlass()
                .environment(services.settings)
                .environment(services.tools)
                .environment(services.history)
                .environment(services.manager)
                .environment(services.subscriptions)
                .environment(services.conversions)
                .environment(services.network)
                .environment(services.speedTest)
                .environment(services.clipboard)
                .environment(services.appState)
                .preferredColorScheme(services.settings.prefs.appearance.colorScheme)
                .frame(minWidth: 860, minHeight: 520)
                .onOpenURL { services.handle(url: $0) }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1080, height: 700)
        .commands { AppCommands(services: services) }

        Settings {
            SettingsView()
                .windowGlass(.sidebar)
                .environment(services.settings)
                .environment(services.tools)
                .environment(services.history)
                .environment(services.manager)
                .environment(services.subscriptions)
                .environment(services.conversions)
                .environment(services.network)
                .environment(services.speedTest)
                .environment(services.appState)
                .preferredColorScheme(services.settings.prefs.appearance.colorScheme)
        }

        MenuBarExtra(isInserted: Binding(
            get: { services.settings.prefs.showMenuBarExtra },
            set: { newValue in
                // Writing an unchanged value still notifies observers and loops the scene graph.
                guard services.settings.prefs.showMenuBarExtra != newValue else { return }
                services.settings.prefs.showMenuBarExtra = newValue
            })) {
            MenuBarContent()
                .environment(services.settings)
                .environment(services.tools)
                .environment(services.manager)
                .environment(services.subscriptions)
                .environment(services.conversions)
                .environment(services.network)
                .environment(services.speedTest)
                .environment(services.clipboard)
                .environment(services.appState)
        } label: {
            MenuBarLabel()
                .environment(services.manager)
                .environment(services.subscriptions)
                .environment(services.conversions)
                .environment(services.network)
                .environment(services.speedTest)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Process-wide singletons, created once and shared by every scene.
@MainActor
final class Services {
    static let shared = Services()

    let settings = AppSettings()
    let tools = ToolStore()
    let history = HistoryStore()
    let clipboard = ClipboardWatcher()
    let appState = AppState()
    let system: SystemIntegration
    let manager: DownloadManager
    let subscriptions: SubscriptionStore
    let conversions: ConversionStore
    let hotKey = GlobalHotKey()
    let forceQuitHotKey = GlobalHotKey.forceQuit()
    let network = NetworkMonitor()
    let speedTest = SpeedTest()

    private init() {
        system = SystemIntegration(settings: settings)
        manager = DownloadManager(settings: settings, tools: tools, history: history, system: system)
        subscriptions = SubscriptionStore(settings: settings, tools: tools, manager: manager)
        conversions = ConversionStore(tools: tools)
        // Keep browser native-messaging manifests pointing at this copy of the app, and the extension copy that
        // browsers load (outside the bundle, so rebuilds and updates never delete it) up to date.
        DispatchQueue.global(qos: .utility).async {
            BrowserBridge.installHosts()
            BrowserBridge.pruneInbox()
            ExtensionInstaller.installFromBundleOrLog()
        }
        applyHotKey()
        applyForceQuitHotKey()
        claimDefaultHandlersIfWanted()
        history.prune(retention: settings.prefs.historyRetention)
        clipboard.setEnabled(settings.prefs.watchClipboard)
        Task { await tools.refresh(channel: settings.prefs.ytdlpChannel) }
        observeSettings()
    }

    /// Re-applies side effects whenever a relevant preference changes.
    private struct WatchedSettings: Equatable {
        var watchClipboard: Bool
        var channel: YtdlpChannel
        var maxConcurrent: Int
        var hotKey: Bool
        var forceQuitHotKey: Bool
        var isDefaultDownloadManager: Bool
    }

    private var watched: WatchedSettings {
        let p = settings.prefs
        return WatchedSettings(watchClipboard: p.watchClipboard, channel: p.ytdlpChannel,
                               maxConcurrent: p.maxConcurrentDownloads, hotKey: p.globalHotKeyEnabled,
                               forceQuitHotKey: p.forceQuitHotKeyEnabled, isDefaultDownloadManager: p.isDefaultDownloadManager)
    }

    /// Re-applies side effects only when one of the watched preferences actually changed.
    private func observeSettings() {
        let before = watched
        withObservationTracking {
            _ = settings.prefs
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let after = self.watched
                    if after.watchClipboard != before.watchClipboard { self.clipboard.setEnabled(after.watchClipboard) }
                    if after.channel != before.channel { Task { await self.tools.refresh(channel: after.channel) } }
                    if after.maxConcurrent != before.maxConcurrent { self.manager.pump() }
                    if after.hotKey != before.hotKey { self.applyHotKey() }
                    if after.forceQuitHotKey != before.forceQuitHotKey { self.applyForceQuitHotKey() }
                    if after.isDefaultDownloadManager != before.isDefaultDownloadManager { self.claimDefaultHandlersIfWanted() }
                    self.observeSettings()
                }
            }
        }
    }

    private func applyHotKey() {
        hotKey.setEnabled(settings.prefs.globalHotKeyEnabled) { [weak self] in
            let text = NSPasteboard.general.string(forType: .string) ?? ""
            let magnet = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("magnet:?")
                ? text.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            guard let self, let url = magnet ?? ClipboardWatcher.firstURL(in: text) else {
                NSSound.beep()
                return
            }
            self.clipboard.markSeen(url)
            self.manager.quickDownload(url: url)
            NSSound(named: "Pop")?.play()
        }
    }

    private func applyForceQuitHotKey() {
        forceQuitHotKey.setEnabled(settings.prefs.forceQuitHotKeyEnabled) {
            ForceQuitWindowController.shared.show()
        }
    }

    /// "Root = default download manager": take magnet links and .torrent files back if another app has them.
    private func claimDefaultHandlersIfWanted() {
        guard settings.prefs.isDefaultDownloadManager else { return }
        if !settings.prefs.browserCatchDownloads { settings.prefs.browserCatchDownloads = true }
        Task { _ = await DefaultDownloadManager.claim() }
    }

    /// A magnet link or .torrent file opened from another app (Root is their default handler): the same
    /// confirm-and-progress window as a caught browser download.
    private func handleExternalDownload(_ link: String) {
        catchDownload(BrowserItem(url: link))
    }

    /// Every caught download goes through here: the FDM-style popup, or straight into the queue when the popup
    /// is off or «Don't ask for … files» was ticked for this type.
    private func catchDownload(_ item: BrowserItem) {
        clipboard.markSeen(item.url)
        switch CatchFlow.route(item, prefs: settings.prefs) {
        case .popup:
            CatchWindowController.shared.present(item, manager: manager, settings: settings)
        case .enqueue where CatchFlow.isMediaPage(item.url):
            manager.quickDownload(url: item.url, headers: item.headers)
        case .enqueue:
            manager.enqueueFile(url: item.url, filename: item.filename, headers: item.headers, size: item.size)
        }
    }

    /// Requests from the browser extension (written to the inbox by the native host).
    private func handleBrowserRequest(id: String) {
        guard let request = BrowserBridge.takeRequest(id: id) else { return }
        let preset = request.preset.flatMap { name in
            settings.prefs.allPresets.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
        switch request.action {
        case "add":
            guard let item = request.items.first else { return }
            // "Download with Root" on one link or page: the same popup as a caught download (quality choices for
            // media pages). With the popup turned off, the full Add sheet as before.
            if settings.prefs.browserShowCatchWindow, request.items.count == 1 {
                catchDownload(item)
            } else {
                NSApp.activate()
                appState.presentAdd(url: item.url, headers: item.headers)
            }
        case "catch":
            // Browser downloads are files: the file engine, with an FDM-style confirm/progress window.
            request.items.forEach(catchDownload)
        case "batch":
            NSApp.activate()
            appState.presentBatchImport(text: request.items.map(\.url).joined(separator: "\n"))
        default:
            // Quick: download in the background without stealing focus.
            for item in request.items {
                clipboard.markSeen(item.url)
                if item.filename != nil {
                    // A caught browser download from an older extension build: still a file, never yt-dlp.
                    manager.enqueueFile(url: item.url, filename: item.filename, headers: item.headers, size: item.size)
                } else {
                    manager.quickDownload(url: item.url, preset: preset, headers: item.headers, filename: item.filename)
                }
            }
        }
    }

    /// `parabolic://add?url=…` (bookmarklet / Shortcuts) and `parabolic://download?url=…&preset=…`.
    func handle(url: URL) {
        if url.isFileURL {
            if url.pathExtension.lowercased() == "torrent" { handleExternalDownload(url.path) }
            return
        }
        if url.scheme?.lowercased() == DefaultDownloadManager.magnetScheme {
            handleExternalDownload(url.absoluteString)
            return
        }
        if url.scheme == "parabolic", url.host == "inbox",
           let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value {
            handleBrowserRequest(id: id)
            return
        }
        guard url.scheme == "parabolic",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let target = components.queryItems?.first(where: { $0.name == "url" })?.value else { return }
        NSApp.activate()
        // Any web page can open parabolic:// links, so they always land in the Add sheet for confirmation.
        // One-click downloads only come from the extension (inbox) or the user's own shortcuts.
        appState.presentAdd(url: target)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let services = Services.shared
            let active = services.manager.runningCount
            if active > 0, services.settings.prefs.confirmQuitWithActiveDownloads {
                let alert = NSAlert()
                alert.messageText = "Quit with \(active) download\(active == 1 ? "" : "s") in progress?"
                alert.informativeText = "Active downloads stop now. They'll be waiting in the list next time, ready to resume."
                alert.addButton(withTitle: "Quit")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
            }
            services.manager.shutdown()
            return .terminateNow
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock icon click with no window open brings the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }

    /// Services menu: "Download with Parabolic" on selected text containing links.
    @objc func downloadFromService(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        MainActor.assumeIsolated {
            guard let text = pasteboard.string(forType: .string) else { return }
            let urls = ClipboardWatcher.allURLs(in: text)
            NSApp.activate()
            if urls.count > 1 {
                Services.shared.appState.presentBatchImport(text: urls.joined(separator: "\n"))
            } else if let url = urls.first {
                Services.shared.appState.presentAdd(url: url)
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        // Window restoration can leave the main window ordered out after a crash or forced quit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return }
            if let main = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
                main.makeKeyAndOrderFront(nil)
            } else {
                // SwiftUI didn't create the window (it was closed last session): a reopen event makes it.
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config)
            }
        }
    }
}

extension AppearanceMode {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
