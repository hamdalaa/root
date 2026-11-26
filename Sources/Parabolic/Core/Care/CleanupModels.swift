import Foundation

/// The kinds of reclaimable space the Cleanup tool scans for, in display and de-duplication order.
enum CleanupCategoryID: String, CaseIterable, Codable, Sendable, Identifiable {
    case userCaches, browserCaches, developer, logs, projectArtifacts, installers, oldDownloads, trash

    var id: String { rawValue }

    var title: String {
        switch self {
        case .userCaches: "App caches"
        case .browserCaches: "Browser caches"
        case .developer: "Developer junk"
        case .logs: "Logs & crash reports"
        case .projectArtifacts: "Project build artifacts"
        case .installers: "Installers"
        case .oldDownloads: "Old downloads"
        case .trash: "Trash"
        }
    }

    var symbol: String {
        switch self {
        case .userCaches: "archivebox"
        case .browserCaches: "safari"
        case .developer: "hammer"
        case .logs: "doc.text.magnifyingglass"
        case .projectArtifacts: "shippingbox"
        case .installers: "opticaldiscdrive"
        case .oldDownloads: "clock.arrow.circlepath"
        case .trash: "trash"
        }
    }

    /// One line on what is in the category.
    var summary: String {
        switch self {
        case .userCaches: "Files apps keep in ~/Library/Caches and rebuild when needed"
        case .browserCaches: "Cached web content only. Profiles, cookies, history and passwords stay"
        case .developer: "Xcode DerivedData, simulator caches and package-manager caches"
        case .logs: "App logs and crash reports in ~/Library/Logs"
        case .projectArtifacts: "node_modules, .build, target and similar folders in idle projects"
        case .installers: "Disk images, packages and installer archives you’ve downloaded"
        case .oldDownloads: "Items in Downloads you haven’t opened or changed in 90 days"
        case .trash: "Everything already in the Trash"
        }
    }

    /// Why a category starts unticked. Nil for the categories that are safe to clean by default.
    var caution: String? {
        switch self {
        case .oldDownloads: "Off by default: these are your files, not junk. Review before cleaning."
        case .trash: "Off by default: emptying the Trash can’t be undone."
        default: nil
        }
    }

    var isSelectedByDefault: Bool { caution == nil }

    /// Only regenerable caches may skip the Trash and be deleted straight away.
    var allowsImmediateDelete: Bool {
        switch self {
        case .userCaches, .browserCaches, .developer: true
        default: false
        }
    }
}

/// One thing the user can tick and clean: a file or folder at a validated path.
struct CleanupItem: Identifiable, Hashable, Sendable {
    /// Standardized path; unique across a scan.
    var id: String { url.path }
    let url: URL
    /// The allowlisted root this item was found under. Cleaning re-checks the item is still inside it.
    let root: URL
    let name: String
    /// Secondary line: owning app, project, folder or profile.
    let detail: String?
    /// Allocated size on disk, measured.
    let bytes: Int64
    /// Last activity the scanner based its decision on, when relevant.
    let lastActivity: Date?
    /// True for regenerable caches (eligible for "Delete immediately").
    let isCache: Bool
    /// Name of the running app this item belongs to, if any. Such items start unticked.
    let inUseBy: String?
    /// Start ticked after a scan (before the in-use rule is applied).
    let prefersSelected: Bool
    /// Why this item starts unticked when it otherwise would be ticked.
    let note: String?

    init(url: URL, root: URL, name: String, detail: String? = nil, bytes: Int64, lastActivity: Date? = nil,
         isCache: Bool, inUseBy: String? = nil, prefersSelected: Bool = true, note: String? = nil) {
        self.url = url.standardizedFileURL
        self.root = root.standardizedFileURL
        self.name = name
        self.detail = detail
        self.bytes = bytes
        self.lastActivity = lastActivity
        self.isCache = isCache
        self.inUseBy = inUseBy
        self.prefersSelected = prefersSelected
        self.note = note
    }

    var isSelectedByDefault: Bool { prefersSelected && inUseBy == nil }
}

/// What one category scan found.
struct CleanupCategoryResult: Sendable, Identifiable {
    var id: CleanupCategoryID { category }
    let category: CleanupCategoryID
    /// Largest first.
    let items: [CleanupItem]
    /// Folders the scan could not read (usually Full Disk Access).
    let deniedCount: Int

    init(category: CleanupCategoryID, items: [CleanupItem], deniedCount: Int) {
        self.category = category
        self.items = items.sorted { $0.bytes > $1.bytes }
        self.deniedCount = deniedCount
    }

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

    func replacingItems(_ items: [CleanupItem]) -> CleanupCategoryResult {
        CleanupCategoryResult(category: category, items: items, deniedCount: deniedCount)
    }
}

/// A running app, as seen at scan time.
struct CleanupRunningApp: Sendable, Hashable {
    let bundleID: String
    let name: String
}

/// Persisted summary of the last scan and the last clean (UserDefaults, `cleanup.history`).
struct CleanupHistory: Codable, Sendable, Equatable {
    var lastScanDate: Date?
    var lastScanBytes: Int64?
    var lastCleanDate: Date?
    /// Measured change in free space after the last clean.
    var lastCleanFreedBytes: Int64?
    var lastCleanTrashedBytes: Int64?
    var lastCleanDeletedBytes: Int64?

    static let defaultsKey = "cleanup.history"

    static func load(from defaults: UserDefaults = .standard) -> CleanupHistory {
        guard let data = defaults.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(CleanupHistory.self, from: data) else { return CleanupHistory() }
        return value
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
