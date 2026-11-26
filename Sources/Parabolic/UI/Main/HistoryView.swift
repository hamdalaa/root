import AppKit
import SwiftUI

/// Everything downloaded before, searchable, with quick re-download.
struct HistoryView: View {
    @Environment(HistoryStore.self) private var history
    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selection: Set<UUID> = []
    @State private var isConfirmingClear = false
    @State private var platformFilter: Platform?

    private var actions: HistoryActions { HistoryActions(history: history, appState: appState) }

    private var query: String { appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var visibleEntries: [HistoryEntry] {
        let query = query
        let platform = platformFilter
        return history.entries.filter { $0.matches(search: query) && (platform == nil || $0.platform == platform) }
    }

    var body: some View {
        let entries = visibleEntries
        ZStack {
            if history.entries.isEmpty {
                ContentUnavailableView {
                    Label("No history yet", systemImage: SidebarItem.history.symbol)
                } description: {
                    Text(emptyMessage)
                }
            } else if entries.isEmpty, query.isEmpty, let platform = platformFilter {
                ContentUnavailableView("No \(platform.title) downloads", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("Nothing in History came from \(platform.title)."))
            } else if entries.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                list(entries)
            }
        }
        .safeAreaBar(edge: .top, spacing: 0) {
            if !history.entries.isEmpty { header }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .animation(.adaptive(reduceMotion), value: history.entries.count)
        .confirmationDialog("Clear all download history?", isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) {
                history.clear()
                selection = []
            }
        } message: {
            Text("Your downloaded files stay where they are. Only this list is cleared.")
        }
    }

    private var emptyMessage: String {
        settings.prefs.historyRetention == .never
            ? "History is turned off in Settings."
            : "Finished downloads are remembered here so you can find or fetch them again."
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("History")
                    .font(.system(size: 22, weight: .semibold))
                Text(summary)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            platformMenu
            Button(role: .destructive) { isConfirmingClear = true } label: {
                Label("Clear History…", systemImage: "trash")
            }
            .buttonStyle(.glass)
            .help("Remove every entry from History")
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    /// Platforms present in History, most used first.
    private var platformsInHistory: [Platform] {
        Dictionary(grouping: history.entries, by: \.platform)
            .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key.title < $1.key.title }
            .map(\.key)
    }

    private var platformMenu: some View {
        Menu {
            Button { platformFilter = nil } label: {
                Label("All Platforms", systemImage: platformFilter == nil ? "checkmark" : "square.stack")
            }
            Divider()
            ForEach(platformsInHistory) { platform in
                Button { platformFilter = platform } label: {
                    Label { Text(platform.title) } icon: { PlatformMenuIcon.image(platform) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if let platformFilter {
                    PlatformGlyph(platform: platformFilter, size: 13)
                } else {
                    Image(systemName: "line.3.horizontal.decrease")
                }
                Text(platformFilter?.title ?? "All Platforms")
            }
            .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .fixedSize()
        .help("Show history from one platform")
        .accessibilityLabel("Platform filter")
        .accessibilityValue(platformFilter?.title ?? "All Platforms")
    }

    private var summary: String {
        let count = history.entries.count
        return "\(count) download\(count == 1 ? "" : "s") · \(Format.bytes(history.totalBytes)) in total"
    }

    /// Plain scroll view so selection is the row's own glass tint, matching the downloads list.
    private func select(_ id: UUID, in ordered: [UUID]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else if flags.contains(.shift), let anchor = ordered.firstIndex(where: selection.contains),
                  let target = ordered.firstIndex(of: id) {
            selection = Set(ordered[min(anchor, target)...max(anchor, target)])
        } else {
            selection = [id]
        }
    }

    private func list(_ entries: [HistoryEntry]) -> some View {
        let ids = entries.map(\.id)
        return ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(entries) { entry in
                    HistoryRow(entry: entry, actions: actions, isSelected: selection.contains(entry.id))
                        .onTapGesture(count: 2) { actions.open([entry]) }
                        .onTapGesture { select(entry.id, in: ids) }
                        .contextMenu {
                            let targets = selection.contains(entry.id) ? actions.entries(selection) : [entry]
                            HistoryContextMenu(entries: targets, actions: actions) { selection.subtract(targets.map(\.id)) }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)
            .animation(.spring(response: 0.36, dampingFraction: 0.88), value: ids)
        }
        .contentMargins(.bottom, 40, for: .scrollContent)
        .background { Color.clear.contentShape(.rect).onTapGesture { selection = [] } }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.return) { actions.open(actions.entries(selection)); return .handled }
        .onDeleteCommand {
            actions.remove(actions.entries(selection))
            selection = []
        }
        .accessibilityLabel("History")
    }
}

/// Actions on one or more history entries.
@MainActor
struct HistoryActions {
    let history: HistoryStore
    let appState: AppState

    func entries(_ ids: Set<UUID>) -> [HistoryEntry] { history.entries.filter { ids.contains($0.id) } }

    func downloadAgain(_ entries: [HistoryEntry]) {
        if entries.count == 1, let entry = entries.first {
            appState.presentAdd(url: entry.url)
        } else if !entries.isEmpty {
            appState.presentBatchImport(text: entries.map(\.url).joined(separator: "\n"))
        }
    }

    func open(_ entries: [HistoryEntry]) {
        for url in entries.compactMap(\.fileURL) { NSWorkspace.shared.open(url) }
    }

    func reveal(_ entries: [HistoryEntry]) {
        FinderReveal.reveal(paths: entries.map(\.filePath))
    }

    func copyLinks(_ entries: [HistoryEntry]) { LinkText.copy(entries.map(\.url)) }

    func remove(_ entries: [HistoryEntry]) { history.remove(Set(entries.map(\.id))) }
}

struct HistoryContextMenu: View {
    let entries: [HistoryEntry]
    let actions: HistoryActions
    var onRemove: () -> Void

    var body: some View {
        if !entries.isEmpty {
            let onDisk = entries.contains(where: \.fileExists)
            Button { actions.downloadAgain(entries) } label: { Label("Download Again…", systemImage: "arrow.down.circle") }
            Divider()
            Button { actions.open(entries) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
                .disabled(!onDisk)
            Button { actions.reveal(entries) } label: { Label("Show in Finder", systemImage: "folder") }
                .disabled(!onDisk)
            Button { actions.copyLinks(entries) } label: {
                Label(entries.count > 1 ? "Copy Links" : "Copy Link", systemImage: "link")
            }
            Divider()
            Button(role: .destructive) {
                actions.remove(entries)
                onRemove()
            } label: { Label("Remove from History", systemImage: "minus.circle") }
        }
    }
}
