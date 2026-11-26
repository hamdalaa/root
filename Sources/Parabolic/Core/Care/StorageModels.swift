import Foundation

// MARK: - Explorer data

/// One child of a scanned folder: a file, a folder (whole subtree measured) or a symlink (never followed).
struct StorageItem: Identifiable, Hashable, Sendable {
    enum Kind: Sendable, Hashable { case file, folder, package, symlink }

    let url: URL
    let kind: Kind
    /// Allocated bytes on disk (st_blocks × 512, identical to `totalFileAllocatedSizeKey`), hard links counted once.
    var bytes: Int64
    /// Regular files inside (1 for a file).
    var fileCount: Int
    /// Folders inside that could not be read (permissions).
    var unreadable: Int
    /// True while a folder is still being measured; `bytes` is the running total.
    var isSizing: Bool

    var id: URL { url }
    var name: String { url.lastPathComponent }
    /// Only real folders can be opened in the explorer; packages (apps, libraries) are shown as one block.
    var canDrill: Bool { kind == .folder }

    init(url: URL, kind: Kind, bytes: Int64, fileCount: Int = 0, unreadable: Int = 0, isSizing: Bool = false) {
        self.url = url
        self.kind = kind
        self.bytes = bytes
        self.fileCount = fileCount
        self.unreadable = unreadable
        self.isSizing = isSizing
    }
}

/// The measured contents of one folder: biggest children individually, the long tail folded into `otherBytes`.
struct StorageListing: Sendable, Equatable {
    var folder: URL
    /// Sorted largest first.
    var items: [StorageItem]
    /// Children beyond `StorageListing.keep`, summed.
    var otherBytes: Int64 = 0
    var otherCount: Int = 0
    /// Folders under this one that couldn't be read, and up to a few of their paths.
    var unreadable: Int = 0
    var unreadableSamples: [String] = []
    /// Children skipped because they are other volumes mounted inside this folder.
    var skippedVolumes: Int = 0
    /// False while sizing, or when the scan was stopped before it finished.
    var isComplete: Bool = false
    /// The folder's own directory blocks (not part of any child).
    var selfBytes: Int64 = 0

    /// How many children a listing keeps individually; the rest become "smaller items".
    static let keep = 400

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } + otherBytes }
    var totalFiles: Int { items.reduce(0) { $0 + $1.fileCount } + otherCount }

    /// Sorts largest first and folds everything past `keep` into the "other" bucket.
    static func make(folder: URL, items: [StorageItem], unreadable: Int = 0, unreadableSamples: [String] = [],
                     skippedVolumes: Int = 0, selfBytes: Int64 = 0, keep: Int = StorageListing.keep,
                     isComplete: Bool) -> StorageListing {
        let sorted = items.sorted(by: StorageListing.order)
        let kept = Array(sorted.prefix(keep))
        let rest = sorted.dropFirst(keep)
        return StorageListing(folder: folder, items: kept,
                              otherBytes: rest.reduce(0) { $0 + $1.bytes },
                              otherCount: rest.reduce(0) { $0 + max(1, $1.fileCount) },
                              unreadable: unreadable, unreadableSamples: unreadableSamples,
                              skippedVolumes: skippedVolumes, isComplete: isComplete, selfBytes: selfBytes)
    }

    /// Largest first; ties broken by name so the order is stable between refreshes.
    static func order(_ a: StorageItem, _ b: StorageItem) -> Bool {
        if a.bytes != b.bytes { return a.bytes > b.bytes }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

/// Events streamed by `StorageScanner.scan(_:)` so the UI can fill in while folders are measured.
enum StorageScanEvent: Sendable {
    /// Every child of the folder (not truncated); files are sized, folders are `isSizing` with 0 bytes.
    case listed(StorageListing)
    /// A folder child's running total.
    case progress(URL, bytes: Int64, files: Int)
    /// A folder child finished; `listings` holds its own contents and those of its subfolders for instant drill-down.
    case sized(StorageItem, listings: [URL: StorageListing], unreadableSamples: [String])
    /// The folder itself couldn't be listed.
    case failed(String, permissionDenied: Bool)
    case finished(cancelled: Bool)
}

// MARK: - Volumes

/// A mounted, browsable volume with capacity figures read from the system.
struct StorageVolume: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let total: Int64
    /// `volumeAvailableCapacityKey`: free right now.
    let free: Int64
    /// `volumeAvailableCapacityForImportantUsageKey`: free plus what macOS can purge. Nil when the volume doesn't report it.
    let availableForImportant: Int64?
    let isInternal: Bool
    let isRemovable: Bool
    let isRoot: Bool
    let isLocal: Bool
    let format: String?

    var id: URL { url }

    /// Space macOS can reclaim on demand (caches, local snapshots, optimised iCloud files).
    var purgeable: Int64 { max(0, (availableForImportant ?? free) - free) }
    /// Space taken by data that isn't purgeable.
    var used: Int64 { max(0, total - free - purgeable) }
    /// What's available for new files, counting purgeable space.
    var available: Int64 { free + purgeable }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    var pressure: StoragePressure { StoragePressure(available: available, total: total) }
}

/// How full a volume is, mapped to the semantic status colours.
enum StoragePressure: Sendable, Equatable {
    case ok, warning, critical

    /// Critical below 5 % or 10 GB available; warning below 15 % or 30 GB.
    init(available: Int64, total: Int64) {
        guard total > 0 else { self = .ok; return }
        let fraction = Double(available) / Double(total)
        let gb: Int64 = 1_000_000_000
        if fraction < 0.05 || available < 10 * gb { self = .critical }
        else if fraction < 0.15 || available < 30 * gb { self = .warning }
        else { self = .ok }
    }

    var label: String {
        switch self {
        case .ok: "Plenty of space"
        case .warning: "Getting full"
        case .critical: "Nearly full"
        }
    }
}
