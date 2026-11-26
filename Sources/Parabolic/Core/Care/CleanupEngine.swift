import AppKit
import CoreServices
import Foundation

/// How a selected item leaves the disk.
enum CleanupAction: String, Sendable {
    /// Moved to the Trash. Space comes back when the Trash is emptied.
    case trash
    /// Removed immediately. Used for emptying the Trash and, when asked, for regenerable caches.
    case delete
}

struct CleanupPlanEntry: Sendable, Identifiable {
    var id: String { item.id }
    let item: CleanupItem
    let category: CleanupCategoryID
    let action: CleanupAction
}

struct CleanupFailure: Sendable, Identifiable {
    var id: String { path }
    let name: String
    let path: String
    let reason: String
}

/// What a clean did, with free space measured on each affected volume before and after.
struct CleanupOutcome: Sendable {
    let date: Date
    let trashedCount: Int
    let trashedBytes: Int64
    let deletedCount: Int
    let deletedBytes: Int64
    let failures: [CleanupFailure]
    /// Sum of (free after − free before) over every volume touched; nil if free space couldn't be read.
    let measuredFreedBytes: Int64?
    let volumeNames: [String]
}

enum CleanupEngine {
    // MARK: De-duplication

    /// Drops any item that is the same as, inside, or a parent of an item already kept by an earlier category,
    /// so no byte is counted or cleaned twice. Category order is `CleanupCategoryID.allCases`.
    static func deduplicate(_ results: [CleanupCategoryResult]) -> [CleanupCategoryResult] {
        let order = CleanupCategoryID.allCases
        let sorted = results.sorted { order.firstIndex(of: $0.category)! < order.firstIndex(of: $1.category)! }
        var kept = Set<String>()
        var keptAncestors = Set<String>()
        return sorted.map { result in
            let items = result.items.filter { item in
                let path = CleanupSafety.realPath(item.url) ?? item.url.path
                if kept.contains(path) || keptAncestors.contains(path) { return false }
                if ancestors(of: path).contains(where: kept.contains) { return false }
                kept.insert(path)
                keptAncestors.formUnion(ancestors(of: path))
                return true
            }
            return result.replacingItems(items)
        }
    }

    static func ancestors(of path: String) -> [String] {
        var result: [String] = []
        var current = (path as NSString).deletingLastPathComponent
        while current.count > 1 {
            result.append(current)
            current = (current as NSString).deletingLastPathComponent
        }
        return result
    }

    // MARK: Planning

    static func plan(_ selected: [(CleanupCategoryID, CleanupItem)], deleteCachesImmediately: Bool) -> [CleanupPlanEntry] {
        selected.map { category, item in
            let action: CleanupAction
            if category == .trash {
                action = .delete
            } else if deleteCachesImmediately, category.allowsImmediateDelete, item.isCache {
                action = .delete
            } else {
                action = .trash
            }
            return CleanupPlanEntry(item: item, category: category, action: action)
        }
    }

    // MARK: Executing

    /// Removes each planned item after re-running the safety gate. Blocking; call off the main thread.
    static func execute(_ plan: [CleanupPlanEntry], env: CleanupEnvironment, cancel: CleanupCancellation,
                        settleDelay: TimeInterval = 1.5, progress: @Sendable (Int, String) -> Void) -> CleanupOutcome {
        let allowlist = env.allowlist
        let trashRoots = ([env.locations.trash] + env.volumeTrashRoots).compactMap(CleanupSafety.realPath)
        let volumes = volumeURLs(for: plan.map(\.item.url) + [env.home])
        let before = freeSpace(volumes)

        var trashedCount = 0, deletedCount = 0
        var trashedBytes: Int64 = 0, deletedBytes: Int64 = 0
        var failures: [CleanupFailure] = []
        let fileManager = FileManager()

        for (index, entry) in plan.enumerated() {
            if cancel.isCancelled { break }
            progress(index, entry.item.name)
            let item = entry.item
            if let rejection = CleanupSafety.check(item.url, root: item.root, allowlist: allowlist, home: env.home) {
                failures.append(CleanupFailure(name: item.name, path: item.url.path, reason: rejection.reason))
                continue
            }
            if entry.category == .trash {
                let real = CleanupSafety.realPath(item.url) ?? ""
                guard trashRoots.contains(where: { CleanupSafety.isStrictlyInside(real, $0) }) else {
                    failures.append(CleanupFailure(name: item.name, path: item.url.path,
                                                   reason: CleanupRejection.notAllowlisted.reason))
                    continue
                }
            }
            do {
                switch entry.action {
                case .trash:
                    try fileManager.trashItem(at: item.url, resultingItemURL: nil)
                    trashedCount += 1
                    trashedBytes += item.bytes
                case .delete:
                    try fileManager.removeItem(at: item.url)
                    deletedCount += 1
                    deletedBytes += item.bytes
                }
            } catch {
                failures.append(CleanupFailure(name: item.name, path: item.url.path, reason: describe(error)))
            }
        }
        progress(plan.count, "")

        if settleDelay > 0 { Thread.sleep(forTimeInterval: settleDelay) }
        let after = freeSpace(volumes)
        var freed: Int64?
        if !before.isEmpty, before.count == after.count {
            freed = before.keys.reduce(Int64(0)) { $0 + ((after[$1] ?? 0) - (before[$1] ?? 0)) }
        }
        return CleanupOutcome(date: Date(), trashedCount: trashedCount, trashedBytes: trashedBytes,
                              deletedCount: deletedCount, deletedBytes: deletedBytes, failures: failures,
                              measuredFreedBytes: freed, volumeNames: volumeNames(volumes))
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        switch (ns.domain, ns.code) {
        case (NSCocoaErrorDomain, NSFileWriteNoPermissionError), (NSCocoaErrorDomain, NSFileReadNoPermissionError):
            return "Permission denied"
        case (NSCocoaErrorDomain, NSFileNoSuchFileError), (NSCocoaErrorDomain, NSFileReadNoSuchFileError):
            return "It no longer exists"
        case (NSCocoaErrorDomain, NSFileWriteVolumeReadOnlyError):
            return "The disk is read-only"
        default:
            return ns.localizedDescription
        }
    }

    // MARK: Free space

    static func volumeURLs(for urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.compactMap { url in
            guard let volume = try? url.resourceValues(forKeys: [.volumeURLKey]).volume,
                  seen.insert(volume.path).inserted else { return nil }
            return volume
        }
    }

    /// Raw free bytes per volume path (`volumeAvailableCapacity`, which excludes purgeable space).
    static func freeSpace(_ volumes: [URL]) -> [String: Int64] {
        var result: [String: Int64] = [:]
        for volume in volumes {
            if let free = try? volume.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity {
                result[volume.path] = Int64(free)
            }
        }
        return result
    }

    static func volumeNames(_ volumes: [URL]) -> [String] {
        volumes.compactMap { try? $0.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName }
    }

    /// Runs blocking work on a global queue so the cooperative pool and the main actor stay free.
    static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }
}

// MARK: - Live environment

enum CleanupLiveEnvironment {
    static let fullDiskAccessURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// Builds the real environment: running apps (main actor), mounted images and volume trashes (background).
    @MainActor
    static func make(projectIdleDays: Int) async -> CleanupEnvironment {
        let own = CleanupSafety.ownBundleIDs
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> CleanupRunningApp? in
            guard let id = app.bundleIdentifier, !own.contains(id) else { return nil }
            return CleanupRunningApp(bundleID: id, name: app.localizedName ?? id)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let (mounted, trashes) = await CleanupEngine.offMain { (mountedImagePaths(), volumeTrashRoots()) }
        return CleanupEnvironment(home: home, runningApps: apps, projectIdleDays: projectIdleDays,
                                  mountedImagePaths: mounted, volumeTrashRoots: trashes, lastTouched: { lastTouched($0) })
    }

    /// Latest of modified, added-to-folder and last-opened (Spotlight) dates.
    @Sendable static func lastTouched(_ url: URL) -> Date? {
        var dates: [Date] = []
        if let modified = CleanupFS.modificationDate(url) { dates.append(modified) }
        if let added = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate {
            dates.append(added)
        }
        if let item = MDItemCreateWithURL(nil, url as CFURL),
           let used = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date {
            dates.append(used)
        }
        return dates.max()
    }

    static func volumeTrashRoots() -> [URL] {
        let uid = String(getuid())
        let volumes = URL(fileURLWithPath: "/Volumes")
        var denied = 0
        return CleanupFS.children(of: volumes, denied: &denied).compactMap { volume in
            guard !CleanupFS.isSymlink(volume) else { return nil }
            let trash = volume.appendingPathComponent(".Trashes").appendingPathComponent(uid)
            return CleanupFS.isDirectory(trash) ? trash : nil
        }
    }

    /// Disk images mounted right now, from `hdiutil info -plist`.
    static func mountedImagePaths() -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseMountedImages(data)
    }

    static func parseMountedImages(_ data: Data) -> Set<String> {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return [] }
        return Set(images.compactMap { ($0["image-path"] as? String).map { URL(fileURLWithPath: $0).standardizedFileURL.path } })
    }
}
