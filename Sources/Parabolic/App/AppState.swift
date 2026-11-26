import AppKit
import Foundation
import Observation

enum SidebarItem: Hashable, Identifiable {
    case all, downloading, queued, completed, failed
    case search, subscriptions
    case history, statistics, speedTest
    /// Mac Care: system tools that sit next to the downloader.
    case memory, storage, cleanup, uninstaller, loginItems, forceQuit
    /// Downloads filtered to one platform.
    case platform(Platform)

    var id: String {
        if case .platform(let p) = self { return "platform-\(p.rawValue)" }
        return title
    }

    var title: String {
        switch self {
        case .all: "All Downloads"
        case .downloading: "Downloading"
        case .queued: "Queued"
        case .completed: "Completed"
        case .failed: "Failed"
        case .search: "Search"
        case .subscriptions: "Subscriptions"
        case .history: "History"
        case .statistics: "Statistics"
        case .speedTest: "Speed Test"
        case .memory: "Memory"
        case .storage: "Storage"
        case .cleanup: "Cleanup"
        case .uninstaller: "Uninstaller"
        case .loginItems: "Login Items"
        case .forceQuit: "Force Quit"
        case .platform(let p): p.title
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.stack.3d.down.right"
        case .downloading: "arrow.down.circle"
        case .queued: "clock"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .search: "magnifyingglass"
        case .subscriptions: "dot.radiowaves.left.and.right"
        case .history: "clock.arrow.circlepath"
        case .statistics: "chart.bar.xaxis"
        case .speedTest: "gauge.with.dots.needle.67percent"
        case .memory: "memorychip"
        case .storage: "internaldrive"
        case .cleanup: "sparkles"
        case .uninstaller: "xmark.bin"
        case .loginItems: "power"
        case .forceQuit: "xmark.octagon"
        case .platform: "globe"
        }
    }

    /// True for selections that show the downloads list.
    var showsDownloads: Bool {
        switch self {
        case .all, .downloading, .queued, .completed, .failed, .platform: true
        default: false
        }
    }
}

/// UI routing state shared by windows, menus and the menu bar extra.
@MainActor
@Observable
final class AppState {
    var sidebarSelection: SidebarItem = .all
    var searchText = ""
    var selectedItemIDs: Set<UUID> = []
    var showInspector = false

    /// Add-download sheet. `addSheetURL` pre-fills (and auto-starts discovery for) the URL field.
    var isAddSheetPresented = false
    var addSheetURL = ""
    var isBatchImportPresented = false
    var batchImportText = ""

    /// Search screen state survives navigation.
    var searchQuery = ""
    var searchSource: SearchSource = .youtube
    var isAddSubscriptionPresented = false
    /// Permissions + catching checks (Set Up Root…). Shows by itself once per `SetupGuide.currentVersion`.
    var isSetupGuidePresented = false

    /// Click = select one, ⌘-click = toggle, ⇧-click = extend range.
    func clickSelect(_ id: UUID, in ordered: [UUID]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selectedItemIDs.contains(id) { selectedItemIDs.remove(id) } else { selectedItemIDs.insert(id) }
        } else if flags.contains(.shift), let anchor = ordered.firstIndex(where: { selectedItemIDs.contains($0) }),
                  let target = ordered.firstIndex(of: id) {
            selectedItemIDs = Set(ordered[min(anchor, target)...max(anchor, target)])
        } else {
            selectedItemIDs = [id]
        }
    }

    /// Arrow-key navigation through the visible list.
    func moveSelection(by step: Int, in ordered: [UUID]) {
        guard !ordered.isEmpty else { return }
        let current = ordered.lastIndex(where: { selectedItemIDs.contains($0) })
        let next = current.map { min(max($0 + step, 0), ordered.count - 1) } ?? (step > 0 ? 0 : ordered.count - 1)
        selectedItemIDs = [ordered[next]]
    }

    /// Browser headers (cookies, referrer) for the link in the add sheet, when it came from the extension.
    var addSheetHeaders: [String: String]?

    func presentAdd(url: String = "", headers: [String: String]? = nil) {
        addSheetURL = url
        addSheetHeaders = headers
        isAddSheetPresented = true
    }

    func presentBatchImport(text: String = "") {
        batchImportText = text
        isBatchImportPresented = true
    }
}
