import AppKit
import SwiftUI

/// The main window: sidebar filters, the downloads list or history, and the inspector.
struct MainWindowView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ToolStore.self) private var tools
    @Environment(HistoryStore.self) private var history
    @Environment(DownloadManager.self) private var manager
    @Environment(ClipboardWatcher.self) private var clipboard
    @Environment(AppState.self) private var appState
    @Environment(SubscriptionStore.self) private var subscriptions
    @Environment(ConversionStore.self) private var conversions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(DownloadsLayout.storageKey) private var layout: DownloadsLayout = .list

    @AppStorage("sidebarVisible") private var savedSidebarVisible = true
    /// Local state drives the animation; AppStorage writes happen outside the animation transaction.
    @State private var showSidebar = true
    @State private var urlText = ""
    @State private var isDropTargeted = false
    @State private var autoStartedHost: String?
    @State private var toastTask: Task<Void, Never>?

    private static let sidebarWidth: CGFloat = 232
    private static let sidebarInset: CGFloat = 8
    private static let sidebarRadius: CGFloat = 20

    private static func sidebarMotion(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.9)
    }

    /// Sidebar scroll fade under the titlebar: fully hidden above the traffic lights' baseline,
    /// fully visible where the first row sits at rest (46pt inset).
    private static let titlebarFadeStart: CGFloat = 28
    private static let titlebarFadeLength: CGFloat = 20
    /// Content fade under the toolbar. The transparent glass titlebar gets no system scroll-edge blur,
    /// so scrolled content dissolves before it reaches the URL field and buttons. Ends above where
    /// screen titles rest, so nothing is faded until it actually scrolls up.
    private static let toolbarFadeStart: CGFloat = 38
    private static let toolbarFadeLength: CGFloat = 22

    /// How long the auto-start confirmation stays up.
    private static let toastDuration: Duration = .seconds(2.6)

    var body: some View {
        @Bindable var appState = appState
        ZStack(alignment: .leading) {
            AmbientBackdrop()
            detail
                // Top-anchored: a screen taller than the window (Storage) overflows downward instead of
                // being centred up under the toolbar, which also kept the clipboard banner below it.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .mask {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: Self.toolbarFadeStart)
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: Self.toolbarFadeLength)
                        Color.black
                    }
                    .ignoresSafeArea()
                }
                // Content shifts with the panel instead of the panel resizing the layout (no relayout jank).
                .padding(.leading, showSidebar ? Self.sidebarWidth + Self.sidebarInset : 0)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            withAnimation(Self.sidebarMotion(reduceMotion)) { showSidebar.toggle() }
                            savedSidebarVisible = showSidebar
                        } label: {
                            Image(systemName: "sidebar.left")
                        }
                        .help(showSidebar ? "Hide sidebar" : "Show sidebar")
                        .accessibilityLabel(showSidebar ? "Hide sidebar" : "Show sidebar")
                    }
                    .sharedBackgroundVisibility(.hidden)
                    ToolbarSpacer(.fixed, placement: .navigation)
                    MainToolbar(urlText: $urlText, manager: manager, settings: settings,
                                clipboard: clipboard, appState: appState, layout: $layout)
                }
                .inspector(isPresented: $appState.showInspector) {
                    DownloadInspector()
                        .inspectorColumnWidth(min: 280, ideal: 330, max: 460)
                }

            // Seamless sidebar: sits directly on the window glass, separated from content only by space.
            MainSidebar()
                .safeAreaPadding(.top, 46)
                .frame(width: Self.sidebarWidth)
                .frame(maxHeight: .infinity)
                .padding(.vertical, Self.sidebarInset)
                .padding(.leading, Self.sidebarInset)
                .ignoresSafeArea(edges: .top)
                // The list scrolls under the transparent titlebar; fade it out before the traffic lights.
                .mask {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: Self.titlebarFadeStart)
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: Self.titlebarFadeLength)
                        Color.black
                    }
                    .ignoresSafeArea(edges: .top)
                }
                .offset(x: showSidebar ? 0 : -(Self.sidebarWidth * 0.35))
                .opacity(showSidebar ? 1 : 0)
                .blur(radius: showSidebar || reduceMotion ? 0 : 6)
                .allowsHitTesting(showSidebar)
        }
        .searchable(text: $appState.searchText, placement: .toolbar, prompt: searchPrompt)
        .toolbar(removing: .title)
        .onAppear { showSidebar = savedSidebarVisible }
        .onDrop(of: DropIntake.types, isTargeted: $isDropTargeted) { providers in
            Task { route(await DropIntake.intake(from: providers)) }
            return true
        }
        .overlay {
            if isDropTargeted {
                DropOverlay().transition(.opacity)
            }
        }
        .animation(.adaptive(reduceMotion, Tokens.quick), value: isDropTargeted)
        .onChange(of: clipboard.detectedURL, initial: true) { _, url in
            handleDetected(url)
        }
        .sheet(isPresented: $appState.isAddSheetPresented) {
            withServices(AddDownloadSheet())
        }
        .sheet(isPresented: $appState.isBatchImportPresented) {
            withServices(BatchImportSheet())
        }
        .sheet(isPresented: $appState.isAddSubscriptionPresented) {
            withServices(AddSubscriptionSheet())
        }
        .sheet(isPresented: $appState.isSetupGuidePresented) {
            withServices(SetupGuideSheet())
        }
        .task {
            // First launch of a version with new permissions or checks: show the setup guide once.
            guard settings.prefs.setupGuideVersion < SetupGuide.currentVersion else { return }
            try? await Task.sleep(for: .seconds(1))
            if await SetupGuide.needsAttention(downloadFolder: settings.prefs.downloadFolder) {
                appState.isSetupGuidePresented = true
            } else {
                settings.prefs.setupGuideVersion = SetupGuide.currentVersion
            }
        }
    }

    // MARK: Detail

    private var detail: some View {
        // The ZStack is the stable container that owns the swap: the animation has to live outside the
        // view whose identity changes, or it is replaced along with the screen and nothing animates.
        ZStack {
            screen
                // One identity per *screen*: the download filters and platforms share the downloads pane, so
                // switching between them filters the rows in place instead of rebuilding the page.
                .id(screenKey)
                // The old screen fades out fast; the new one starts a beat later and settles in with a soft
                // lift and a hint of scale, so the two never ghost over each other and nothing cuts.
                .transition(screenTransition)
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.34), value: screenKey)
        .safeAreaBar(edge: .top, spacing: 0) {
            // An inset, not an overlay, so the banner pushes the screen title down instead of covering it.
            if bannerURL != nil || autoStartedHost != nil { topBanner }
        }
        .animation(.adaptive(reduceMotion), value: bannerURL)
        .animation(.adaptive(reduceMotion), value: autoStartedHost)
    }

    @ViewBuilder private var screen: some View {
        switch appState.sidebarSelection {
        case .history: HistoryView()
        case .search: SearchView()
        case .subscriptions: SubscriptionsView()
        case .statistics: StatisticsView()
        case .speedTest: SpeedTestView()
        case .memory: MemoryView()
        case .storage: StorageView()
        case .cleanup: CleanupView()
        case .uninstaller: UninstallerView()
        case .loginItems: LoginItemsView()
        case .forceQuit: ForceQuitPage()
        default: DownloadsPane()
        }
    }

    private var screenTransition: AnyTransition {
        if reduceMotion { return .opacity.animation(.easeOut(duration: 0.15)) }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .offset(y: 10))
                .combined(with: .scale(scale: 0.99, anchor: .top))
                .animation(.smooth(duration: 0.34).delay(0.08)),
            removal: .opacity.animation(.easeOut(duration: 0.08)))
    }

    /// Identity of the screen on show; every downloads filter maps to the same key.
    private var screenKey: String {
        appState.sidebarSelection.showsDownloads ? "downloads" : appState.sidebarSelection.id
    }

    /// The toolbar search field only exists on the downloads and history screens.
    private var searchPrompt: String {
        switch appState.sidebarSelection {
        case .history: "Search history"
        case .search, .subscriptions, .statistics, .speedTest: "Search"
        case .uninstaller, .forceQuit: "Search apps"
        case .loginItems: "Search login items"
        case .memory, .storage, .cleanup: "Search"
        case .all, .downloading, .queued, .completed, .failed, .platform: "Search downloads"
        }
    }

    /// The copied link to offer, only when the banner should be visible.
    private var bannerURL: String? {
        guard settings.prefs.watchClipboard, !settings.prefs.autoStartFromClipboard else { return nil }
        return clipboard.detectedURL
    }

    @ViewBuilder private var topBanner: some View {
        Group {
            if let url = bannerURL {
                ClipboardBanner(
                    url: url,
                    onDownload: {
                        clipboard.dismiss()
                        appState.presentAdd(url: url)
                    },
                    onQuickDownload: {
                        clipboard.dismiss()
                        manager.quickDownload(url: url)
                    },
                    onDismiss: { clipboard.dismiss() }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            } else if let host = autoStartedHost {
                AutoStartToast(host: host)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, Tokens.space4)
        .padding(.top, Tokens.space3)
    }

    // MARK: Clipboard

    private func handleDetected(_ url: String?) {
        guard let url, settings.prefs.watchClipboard, settings.prefs.autoStartFromClipboard else { return }
        clipboard.markSeen(url)
        clipboard.dismiss()
        manager.quickDownload(url: url)
        showToast(host: LinkText.host(of: url))
    }

    private func showToast(host: String) {
        toastTask?.cancel()
        autoStartedHost = host
        toastTask = Task {
            try? await Task.sleep(for: Self.toastDuration)
            guard !Task.isCancelled else { return }
            autoStartedHost = nil
        }
    }

    // MARK: Drop

    private func route(_ drop: DropIntake.Result) {
        guard !drop.isEmpty else { NSSound.beep(); return }
        drop.torrentFiles.forEach { manager.quickDownload(url: $0) }
        guard !drop.links.isEmpty else { return }
        route(drop.links)
    }

    private func route(_ links: [String]) {
        switch links.count {
        case 0: NSSound.beep()
        case 1: appState.presentAdd(url: links[0])
        default: appState.presentBatchImport(text: links.joined(separator: "\n"))
        }
    }

    // MARK: Sheets

    private func withServices<Content: View>(_ content: Content) -> some View {
        content
            .environment(settings)
            .environment(tools)
            .environment(history)
            .environment(manager)
            .environment(clipboard)
            .environment(appState)
            .environment(subscriptions)
            .environment(conversions)
    }
}
