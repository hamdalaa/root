import QuickLook
import SwiftUI

/// The downloads list for the current sidebar filter and search, with its floating footer bar.
struct DownloadsPane: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(AppState.self) private var appState
    @Environment(ConversionStore.self) private var conversions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(DownloadsLayout.storageKey) private var layout: DownloadsLayout = .list

    @State private var quickLookURL: URL?


    private var actions: DownloadActions { DownloadActions(manager: manager, appState: appState, conversions: conversions) }

    private var query: String { appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var visibleItems: [DownloadItem] {
        let filter = appState.sidebarSelection
        let query = query
        return manager.items.filter { filter.includes($0) && $0.matches(search: query) }
    }

    var body: some View {
        let items = visibleItems
        ZStack {
            if items.isEmpty {
                emptyState
                    .transition(.opacity)
            } else if layout == .grid {
                DownloadsGrid(items: items, actions: actions, onQuickLook: { quickLookURL = $0 }, header: header(items))
                    .onKeyPress(.space) { toggleQuickLook() ? .handled : .ignored }
                    .transition(.opacity)
            } else {
                list(items)
                    .transition(.opacity)
            }
        }
        .animation(.adaptive(reduceMotion, Tokens.quick), value: layout)
        // The title scrolls away with the rows; only the toolbar keeps a soft fade above them.
        .scrollEdgeEffectStyle(.soft, for: .top)
        .overlay(alignment: .bottom) {
            // Always present: it carries the live network chip even before the first download.
            DownloadsFooterBar(actions: actions)
                .padding(.horizontal, Tokens.space4)
                .padding(.bottom, Tokens.space3)
        }
        .animation(.adaptive(reduceMotion), value: items.isEmpty)
        .animation(.adaptive(reduceMotion), value: manager.items.isEmpty)
        .quickLookPreview($quickLookURL, in: items.compactMap(\.completedFileURL))
    }

    private func header(_ items: [DownloadItem]) -> AnyView {
        AnyView(DownloadsHeader(filter: appState.sidebarSelection, items: items))
    }

    /// Plain scroll view (not List) so selection is drawn by the row's own glass, not a system highlight.
    private func list(_ items: [DownloadItem]) -> some View {
        let ids = items.map(\.id)
        return ScrollView {
            header(items)
            LazyVStack(spacing: 8) {
                ForEach(items) { item in
                    DownloadRow(item: item, actions: actions, isSelected: appState.selectedItemIDs.contains(item.id))
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.97)),
                            removal: .opacity.combined(with: .scale(scale: 0.95))))
                        .onTapGesture(count: 2) { actions.open([item]) }
                        .onTapGesture { appState.clickSelect(item.id, in: ids) }
                        // VoiceOver / AX press selects the row, like a click.
                        .accessibilityAction { appState.clickSelect(item.id, in: ids) }
                        .contextMenu { rowMenu(for: item) }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .animation(.adaptive(reduceMotion, .spring(response: 0.38, dampingFraction: 0.86)), value: ids)
        }
        .contentMargins(.bottom, 80, for: .scrollContent)
        .background {
            Color.clear.contentShape(.rect).onTapGesture { appState.selectedItemIDs = [] }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { appState.moveSelection(by: 1, in: ids); return .handled }
        .onKeyPress(.upArrow) { appState.moveSelection(by: -1, in: ids); return .handled }
        .onKeyPress(.return) { actions.open(actions.items(appState.selectedItemIDs)); return .handled }
        .onDeleteCommand {
            actions.remove(actions.items(appState.selectedItemIDs))
        }
        .onKeyPress(.space) {
            toggleQuickLook() ? .handled : .ignored
        }
        .accessibilityLabel("Downloads")
    }

    /// Right-click acts on the whole selection when the row is part of it, else just this row.
    private func rowMenu(for item: DownloadItem) -> some View {
        let targets = appState.selectedItemIDs.contains(item.id) ? actions.items(appState.selectedItemIDs) : [item]
        return DownloadContextMenu(items: targets, actions: actions) { quickLookURL = $0 }
    }

    /// Space bar: preview the selected completed file, or close the preview.
    private func toggleQuickLook() -> Bool {
        if quickLookURL != nil {
            quickLookURL = nil
            return true
        }
        guard let url = actions.items(appState.selectedItemIDs).compactMap(\.completedFileURL).first else { return false }
        quickLookURL = url
        return true
    }

    @ViewBuilder private var emptyState: some View {
        if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else if appState.sidebarSelection == .all {
            WelcomeDropZone()
        } else {
            FilterEmptyView(filter: appState.sidebarSelection)
        }
    }
}

/// One strong title per screen: the filter (or platform) name with a live summary.
struct DownloadsHeader: View {
    let filter: SidebarItem
    let items: [DownloadItem]

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let platform = filter.platform {
                PlatformBadge(platform: platform, size: 34)
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(filter.title)
                    .font(.system(size: 22, weight: .semibold))
                    .contentTransition(.opacity)
                Text(summary)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .animation(.smooth(duration: 0.28), value: filter)
        .animation(.smooth(duration: 0.28), value: items.count)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var summary: String {
        let count = items.count
        var parts = ["\(count) item\(count == 1 ? "" : "s")"]
        let active = items.filter { $0.status.isActive }.count
        if active > 0 { parts.append("\(active) active") }
        let bytes = items.compactMap(\.totalBytes).reduce(0, +)
        if bytes > 0 { parts.append(Format.bytes(bytes)) }
        return parts.joined(separator: " · ")
    }
}
