import Foundation
import Observation

/// Explorer state: where you are, what's been measured (cached per folder for instant back-navigation) and the live scan.
/// Shared so results survive switching sidebar screens; the scan itself stops when the screen goes away.
@MainActor
@Observable
final class StorageExplorerModel {
    static let shared = StorageExplorerModel()

    enum Phase: Equatable {
        /// Nothing measured here yet.
        case idle
        case scanning
        case done
        /// A scan here was stopped before it finished; figures are partial.
        case stopped
        case failed(String, permissionDenied: Bool)
    }

    struct ScanProgress: Equatable {
        var sized = 0
        var total = 0
    }

    let home = FileManager.default.homeDirectoryForCurrentUser

    /// The folder or disk the user chose to explore; breadcrumbs start here.
    private(set) var base: URL
    private(set) var location: URL
    private(set) var backStack: [URL] = []
    private(set) var listings: [String: StorageListing] = [:]
    private(set) var failures: [String: Phase] = [:]
    private(set) var scanningPath: String?
    private(set) var progress = ScanProgress()
    private(set) var hasFullDiskAccess = true

    /// Item under the pointer in the treemap or list.
    private(set) var hovered: URL?
    /// Selected row / tile.
    private(set) var selection: URL?

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var resumeOnAppear = false

    init() {
        base = home
        location = home
    }

    // MARK: Derived

    var listing: StorageListing? { listings[location.path] }

    var phase: Phase {
        let key = location.path
        if scanningPath == key { return .scanning }
        if let failure = failures[key] { return failure }
        guard let listing = listings[key] else { return .idle }
        return listing.isComplete ? .done : .stopped
    }

    var canGoBack: Bool { !backStack.isEmpty }

    /// Folders from `base` down to `location`.
    var crumbs: [URL] {
        let basePath = base.path
        let path = location.path
        guard path == basePath || path.hasPrefix(basePath == "/" ? "/" : basePath + "/") else { return [location] }
        var result = [base]
        let rest = path.dropFirst(basePath.count).split(separator: "/")
        var current = base
        for part in rest {
            current = current.appendingPathComponent(String(part), isDirectory: true)
            result.append(current)
        }
        return result
    }

    func listing(for url: URL) -> StorageListing? { listings[url.path] }

    func item(for url: URL) -> StorageItem? { listing?.items.first { $0.url == url } }

    // MARK: Hover / selection (equality-guarded to keep the scene graph quiet)

    func hover(_ url: URL?) { if hovered != url { hovered = url } }
    func select(_ url: URL?) { if selection != url { selection = url } }

    // MARK: Navigation

    /// Starts exploring a new folder or disk from the top.
    func explore(_ url: URL) {
        base = url
        backStack.removeAll()
        move(to: url)
    }

    /// Opens a folder inside the current one (or any crumb).
    func open(_ url: URL) {
        guard url.path != location.path else { return }
        backStack.append(location)
        move(to: url)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        if !(previous.path == base.path || previous.path.hasPrefix(base.path == "/" ? "/" : base.path + "/")) { base = previous }
        move(to: previous)
    }

    func goToParent() {
        guard location.path != base.path else { return }
        open(location.deletingLastPathComponent())
    }

    private func move(to url: URL) {
        location = url
        select(nil)
        hover(nil)
        let key = url.path
        if scanningPath != nil && scanningPath != key { stopScan() }
        if listings[key]?.isComplete != true && scanningPath != key { scan(url) }
    }

    // MARK: Lifecycle

    func appeared() {
        hasFullDiskAccess = StorageSafety.hasFullDiskAccess()
        if resumeOnAppear {
            resumeOnAppear = false
            if listing?.isComplete != true { scan(location) }
        }
    }

    func disappeared() {
        if scanningPath != nil {
            resumeOnAppear = true
            stopScan()
        }
    }

    // MARK: Scanning

    func rescan() {
        let prefix = location.path == "/" ? "/" : location.path + "/"
        listings = listings.filter { key, _ in key != location.path && !key.hasPrefix(prefix) }
        failures[location.path] = nil
        scan(location)
    }

    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        if let key = scanningPath, var listing = listings[key] {
            listing.isComplete = false
            listings[key] = listing
        }
        scanningPath = nil
    }

    private func scan(_ folder: URL) {
        scanTask?.cancel()
        let key = folder.path
        failures[key] = nil
        scanningPath = key
        progress = ScanProgress()
        hasFullDiskAccess = StorageSafety.hasFullDiskAccess()

        // Children that are already fully measured don't need walking again.
        var known: [String: StorageItem] = [:]
        for (path, listing) in listings where listing.isComplete && (path as NSString).deletingLastPathComponent == key {
            known[path] = StorageItem(url: listing.folder, kind: .folder, bytes: listing.totalBytes + listing.selfBytes,
                                      fileCount: listing.totalFiles, unreadable: listing.unreadable)
        }

        scanTask = Task { [weak self] in
            var working = StorageScanAccumulator(folder: folder)
            var lastPublish = ContinuousClock.now
            for await event in StorageScanner.scan(folder, known: known) {
                guard let self, !Task.isCancelled else { break }
                switch event {
                case .listed(let listing):
                    working.start(listing)
                    progress = ScanProgress(sized: 0, total: working.pendingCount)
                    publish(working, key: key)
                case .progress(let url, let bytes, let files):
                    working.update(url, bytes: bytes, files: files)
                case .sized(let item, let sub, let samples):
                    working.finish(item, samples: samples)
                    for (url, listing) in sub { listings[url.path] = listing }
                    progress.sized += 1
                case .failed(let message, let denied):
                    failures[key] = .failed(message, permissionDenied: denied)
                case .finished(let cancelled):
                    working.isComplete = !cancelled && failures[key] == nil
                    if failures[key] == nil { publish(working, key: key) }
                    if scanningPath == key { scanningPath = nil }
                    return
                }
                let now = ContinuousClock.now
                if now - lastPublish > .milliseconds(140) {
                    lastPublish = now
                    publish(working, key: key)
                }
            }
        }
    }

    private func publish(_ working: StorageScanAccumulator, key: String) {
        let listing = working.listing
        if listings[key] != listing { listings[key] = listing }
    }

    // MARK: Trash

    /// Moves items to the Trash and updates every cached total that contained them. Returns failures.
    func trash(_ urls: [URL]) async -> [(URL, String)] {
        let failures = await StorageSafety.trash(urls)
        let failed = Set(failures.map { $0.0.path })
        for url in urls where !failed.contains(url.path) { forget(url) }
        if !urls.isEmpty { await StorageVolumesStore.shared.refresh() }
        return failures
    }

    /// Removes a trashed path from the cache and subtracts its size from every cached ancestor.
    /// `bytes` is used when the explorer never measured the item itself (e.g. trashed from Large Files).
    func forget(_ url: URL, bytes knownBytes: Int64? = nil) {
        let path = url.path
        let parentPath = url.deletingLastPathComponent().path
        let removed = listings[parentPath]?.items.first { $0.url.path == path }
        let bytes = removed?.bytes ?? listings[path].map { $0.totalBytes + $0.selfBytes } ?? knownBytes ?? 0
        let files = removed?.fileCount ?? listings[path]?.totalFiles ?? (knownBytes == nil ? 0 : 1)

        var updated = listings.filter { key, _ in key != path && !key.hasPrefix(path + "/") }
        for (key, var listing) in updated {
            let prefix = key == "/" ? "/" : key + "/"
            guard path.hasPrefix(prefix) else { continue }
            if key == parentPath {
                let before = listing.items.count
                listing.items.removeAll { $0.url.path == path }
                // Folded into "smaller items": take it out of the tail instead.
                if listing.items.count == before, listing.otherCount > 0 {
                    listing.otherBytes = max(0, listing.otherBytes - bytes)
                    listing.otherCount -= 1
                }
            } else if let index = listing.items.firstIndex(where: { path.hasPrefix($0.url.path + "/") }) {
                listing.items[index].bytes = max(0, listing.items[index].bytes - bytes)
                listing.items[index].fileCount = max(0, listing.items[index].fileCount - files)
                listing.items.sort(by: StorageListing.order)
            }
            updated[key] = listing
        }
        listings = updated
        if selection?.path == path { select(nil) }
        if hovered?.path == path { hover(nil) }
        StorageIcons.forget(url)
    }
}

/// Builds the live listing of the folder being scanned from streamed events.
private struct StorageScanAccumulator {
    let folder: URL
    private var items: [StorageItem] = []
    private var index: [URL: Int] = [:]
    private var skippedVolumes = 0
    private var selfBytes: Int64 = 0
    private var samples: [String] = []
    var isComplete = false

    init(folder: URL) { self.folder = folder }

    var pendingCount: Int { items.filter(\.isSizing).count }

    mutating func start(_ listing: StorageListing) {
        items = listing.items
        index = Dictionary(items.enumerated().map { ($1.url, $0) }, uniquingKeysWith: { first, _ in first })
        skippedVolumes = listing.skippedVolumes
        selfBytes = listing.selfBytes
        isComplete = listing.isComplete
    }

    mutating func update(_ url: URL, bytes: Int64, files: Int) {
        guard let i = index[url] else { return }
        items[i].bytes = bytes
        items[i].fileCount = files
    }

    mutating func finish(_ item: StorageItem, samples new: [String]) {
        guard let i = index[item.url] else { return }
        items[i] = item
        for sample in new where samples.count < StorageScanner.sampleLimit { samples.append(sample) }
    }

    var listing: StorageListing {
        StorageListing.make(folder: folder, items: items, unreadable: items.reduce(0) { $0 + $1.unreadable },
                            unreadableSamples: samples, skippedVolumes: skippedVolumes, selfBytes: selfBytes,
                            isComplete: isComplete)
    }
}
