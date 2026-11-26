import SwiftUI

/// Search YouTube, SoundCloud, Bilibili and Niconico through yt-dlp and download from the results.
struct SearchView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var settings
    @Environment(ToolStore.self) private var tools
    @Environment(DownloadManager.self) private var manager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var model = SearchModel.shared
    @AppStorage("search.recent") private var recentJSON = "[]"

    private static let minCardWidth: CGFloat = 220
    private static let gridSpacing: CGFloat = 16
    private static let skeletonCount = 8

    private var query: String { appState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var queryIsLink: Bool { TypedLinkRecognizer.looksLikeLink(query) }
    private var recents: [RecentSearch] { RecentSearch.decode(recentJSON) }
    private var resultPlatform: Platform { model.resultSource.platform }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.space5) {
                SearchHeader(isSelecting: model.isSelecting, canSelect: model.phase == .loaded && !model.results.isEmpty,
                             isLoading: model.phase == .loading, onSubmit: submit, onToggleSelect: toggleSelectMode)
                content
            }
            .padding(.horizontal, Tokens.space6)
            .padding(.top, Tokens.space5)
            .padding(.bottom, model.isSelecting ? 104 : Tokens.space6)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .overlay(alignment: .bottom) {
            if model.isSelecting {
                SearchSelectionBar(count: model.selection.count, total: model.results.count,
                                   onSelectAll: { model.selection = Set(model.results.map(\.id)) },
                                   onCancel: toggleSelectMode, onDownload: downloadSelected)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : Tokens.motion, value: model.isSelecting)
        .animation(reduceMotion ? nil : Tokens.quick, value: model.phase)
        .onChange(of: appState.searchSource) {
            // Switching source re-runs the current search there.
            if !model.resultQuery.isEmpty, !query.isEmpty, !queryIsLink { submit() }
        }
        .onExitCommand { if model.isSelecting { toggleSelectMode() } }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: Tokens.space5) {
            if queryIsLink {
                OpenLinkCard(link: query) { appState.presentAdd(url: query) }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            switch model.phase {
            case .idle:
                SearchInitialState(recents: recents, onPick: pick, onRemove: removeRecent, onClear: { recentJSON = "[]" })
            case .loading:
                grid {
                    ForEach(0..<Self.skeletonCount, id: \.self) { _ in SearchSkeletonCard() }
                }
                .accessibilityLabel("Searching")
            case .loaded where model.results.isEmpty:
                noResults
            case .loaded:
                resultsHeader
                grid {
                    ForEach(model.results) { entry in
                        SearchResultCard(entry: entry, platform: resultPlatform,
                                         isQueued: model.isQueued(entry), isSelecting: model.isSelecting,
                                         isSelected: model.selection.contains(entry.id),
                                         onDownload: { download([entry]) },
                                         onOptions: { appState.presentAdd(url: entry.url) },
                                         onToggle: { select(entry) })
                    }
                }
            case .failed(let message):
                DiscoverMessage(symbol: "exclamationmark.triangle", title: "Search didn't work", message: message, tint: .red) {
                    Button("Try Again", systemImage: "arrow.clockwise", action: submit)
                        .buttonStyle(.glass)
                        .controlSize(.large)
                }
            case .toolMissing:
                toolMissing
            }
        }
    }

    private var resultsHeader: some View {
        HStack(spacing: 6) {
            PlatformGlyph(platform: resultPlatform, size: 13)
            Text("\(model.results.count) results for “\(model.resultQuery)”")
                .font(.system(size: 13, weight: .medium))
            Text("on \(resultPlatform.title)")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var noResults: some View {
        DiscoverMessage(symbol: "magnifyingglass", title: "No results for “\(model.resultQuery)”",
                        message: "Check the spelling or try another site.") {
            HStack(spacing: Tokens.space2) {
                ForEach(SearchSource.allCases.filter { $0 != model.resultSource }) { source in
                    Button {
                        appState.searchSource = source
                    } label: {
                        Label { Text(source.platform.title) } icon: { PlatformGlyph(platform: source.platform, size: 13) }
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Search \(source.platform.title) instead")
                }
            }
        }
    }

    private var toolMissing: some View {
        DiscoverMessage(symbol: "shippingbox", title: "yt-dlp isn't installed",
                        message: tools.lastMessage ?? "Search runs through yt-dlp. Install the official build to start searching.",
                        tint: .parabolicAccent) {
            if tools.isUpdating {
                ProgressView().controlSize(.small).accessibilityLabel("Installing yt-dlp")
            } else {
                Button("Install yt-dlp", systemImage: "arrow.down.app") {
                    Task {
                        await tools.installManagedYtdlp(nightly: false)
                        if tools.isReady { submit() }
                    }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
        }
    }

    /// Responsive grid. Cards size themselves from the column, so nothing here feeds a minimum width back
    /// into the split view (fixed widths derived from a measured width cause AppKit constraint loops).
    private func grid<Cards: View>(@ViewBuilder cards: () -> Cards) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.minCardWidth), spacing: Self.gridSpacing, alignment: .top)],
                  alignment: .leading, spacing: Self.gridSpacing) {
            cards()
        }
    }

    // MARK: Actions

    private func submit() {
        guard !query.isEmpty else { model.reset(); return }
        if queryIsLink {
            appState.presentAdd(url: query)
            return
        }
        let source = appState.searchSource
        recentJSON = RecentSearch.encode(RecentSearch.adding(RecentSearch(query: query, source: source), to: recents))
        model.run(query, source: source, prefs: settings.prefs, tools: tools.paths)
    }

    private func pick(_ recent: RecentSearch) {
        appState.searchQuery = recent.query
        appState.searchSource = recent.source
        model.run(recent.query, source: recent.source, prefs: settings.prefs, tools: tools.paths)
        recentJSON = RecentSearch.encode(RecentSearch.adding(recent, to: recents))
    }

    private func removeRecent(_ recent: RecentSearch) {
        recentJSON = RecentSearch.encode(recents.filter { $0.id != recent.id })
    }

    private func select(_ entry: PlaylistEntry) {
        if !model.isSelecting { model.isSelecting = true }
        model.toggle(entry)
    }

    private func toggleSelectMode() {
        model.isSelecting.toggle()
        model.selection = []
    }

    private func download(_ entries: [PlaylistEntry]) {
        let preset = settings.prefs.preset(for: resultPlatform)
        for entry in entries { manager.quickDownload(url: entry.url, preset: preset) }
        withAnimation(reduceMotion ? nil : Tokens.quick) { model.markQueued(entries.map(\.url)) }
    }

    private func downloadSelected() {
        download(model.selectedEntries)
        toggleSelectMode()
    }
}
