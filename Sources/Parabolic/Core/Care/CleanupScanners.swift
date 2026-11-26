import Foundation

/// Category scanners. Each is synchronous, reads only, and is safe to run on a background queue.
enum CleanupScanner {
    static func scan(_ category: CleanupCategoryID, env: CleanupEnvironment,
                     cancel: CleanupCancellation = CleanupCancellation()) -> CleanupCategoryResult {
        switch category {
        case .userCaches: userCaches(env, cancel)
        case .browserCaches: browserCaches(env, cancel)
        case .developer: developer(env, cancel)
        case .logs: logs(env, cancel)
        case .projectArtifacts: CleanupProjectScanner.scan(env, cancel)
        case .installers: CleanupFileScanners.installers(env, cancel)
        case .oldDownloads: CleanupFileScanners.oldDownloads(env, cancel)
        case .trash: trash(env, cancel)
        }
    }

    // MARK: App caches

    static func userCaches(_ env: CleanupEnvironment, _ cancel: CleanupCancellation) -> CleanupCategoryResult {
        let loc = env.locations
        let claimed = loc.claimedCachePaths
        var denied = 0
        var collector = CleanupCollector(env: env, cancel: cancel)

        // Folders that contain a claimed path are opened one level so the rest of them is still offered.
        func visit(_ folder: URL, owner: String?) {
            for child in CleanupFS.children(of: folder, denied: &denied) {
                if cancel.isCancelled { return }
                let path = child.standardizedFileURL.path
                if claimed.contains(path) { continue }
                let isTopLevel = folder.path == loc.caches.path
                if isTopLevel, isSystemManagedCache(child.lastPathComponent) { continue }
                let isAncestorOfClaimed = claimed.contains { CleanupSafety.isStrictlyInside($0, path) }
                let name = child.lastPathComponent
                let appOwner = owner ?? env.runningOwner(ofFolderNamed: name)
                if isAncestorOfClaimed {
                    if CleanupFS.isDirectory(child) { visit(child, owner: appOwner) }
                    continue
                }
                collector.add(child, root: loc.caches, name: name,
                              detail: isTopLevel ? nil : folder.lastPathComponent,
                              isCache: true, inUseBy: appOwner)
            }
        }
        visit(loc.caches, owner: nil)
        return collector.result(.userCaches, extraDenied: denied)
    }

    /// Apple-managed caches are rebuilt by system daemons and are mostly unreadable without Full Disk Access.
    static func isSystemManagedCache(_ name: String) -> Bool {
        name.hasPrefix("com.apple.") || ["CloudKit", "FamilyCircle", "GeoServices", "Parabolic", "Root"].contains(name)
    }

    // MARK: Browser caches

    static func browserCaches(_ env: CleanupEnvironment, _ cancel: CleanupCancellation) -> CleanupCategoryResult {
        var collector = CleanupCollector(env: env, cancel: cancel)
        var denied = 0
        for browser in CleanupBrowser.all {
            if cancel.isCancelled { break }
            let owner = env.runningApp(withAnyOf: [browser.bundleID])
            for subpath in browser.cacheSubpaths {
                let folder = env.home.appendingPathComponent(subpath)
                guard CleanupFS.isDirectory(folder) else { continue }
                // Itemise the folder's children so the folder itself (which the browser expects) survives.
                for child in CleanupFS.children(of: folder, denied: &denied) {
                    collector.add(child, root: folder, name: browser.name,
                                  detail: child.lastPathComponent, isCache: true, inUseBy: owner)
                }
            }
            guard let profileSubpath = browser.profileRootSubpath else { continue }
            let userData = env.home.appendingPathComponent(profileSubpath)
            guard CleanupFS.isDirectory(userData) else { continue }
            for name in CleanupBrowser.chromiumRootCacheNames {
                collector.add(userData.appendingPathComponent(name), root: userData, name: browser.name,
                              detail: name, isCache: true, inUseBy: owner)
            }
            for profile in CleanupFS.children(of: userData, denied: &denied)
            where CleanupBrowser.isChromiumProfileName(profile.lastPathComponent) && CleanupFS.isDirectory(profile) {
                for name in CleanupBrowser.chromiumProfileCacheNames {
                    collector.add(profile.appendingPathComponent(name), root: userData, name: browser.name,
                                  detail: "\(name) · \(profile.lastPathComponent)", isCache: true, inUseBy: owner)
                }
            }
        }
        return collector.result(.browserCaches, extraDenied: denied)
    }

    // MARK: Developer

    static func developer(_ env: CleanupEnvironment, _ cancel: CleanupCancellation) -> CleanupCategoryResult {
        var collector = CleanupCollector(env: env, cancel: cancel)
        var denied = 0
        for cache in CleanupDevCache.all {
            if cancel.isCancelled { break }
            let folder = cache.folder(home: env.home)
            let owner = env.runningApp(withAnyOf: cache.ownerBundleIDs)
            if cache.listsChildren {
                for child in CleanupFS.children(of: folder, denied: &denied) {
                    let label = cache.subpath.hasSuffix("DerivedData")
                        ? CleanupNaming.derivedDataProject(child.lastPathComponent) : child.lastPathComponent
                    collector.add(child, root: folder, name: label, detail: cache.name, isCache: cache.isCache,
                                  inUseBy: owner, prefersSelected: cache.prefersSelected, note: cache.note)
                }
            } else {
                collector.add(folder, root: cache.root(home: env.home), name: cache.name,
                              detail: "~/" + cache.subpath, isCache: cache.isCache, inUseBy: owner,
                              prefersSelected: cache.prefersSelected, note: cache.note)
            }
        }
        return collector.result(.developer, extraDenied: denied)
    }

    // MARK: Logs

    static func logs(_ env: CleanupEnvironment, _ cancel: CleanupCancellation) -> CleanupCategoryResult {
        let loc = env.locations
        var collector = CleanupCollector(env: env, cancel: cancel)
        var denied = 0
        for child in CleanupFS.children(of: loc.logs, denied: &denied) {
            let name = child.lastPathComponent
            if name == "DiagnosticReports" || isSystemManagedCache(name) { continue }
            collector.add(child, root: loc.logs, name: name, detail: "Log", isCache: false,
                          inUseBy: env.runningOwner(ofFolderNamed: name))
        }
        for child in CleanupFS.children(of: loc.diagnosticReports, denied: &denied) {
            collector.add(child, root: loc.diagnosticReports, name: child.lastPathComponent,
                          detail: "Crash report", isCache: false, inUseBy: nil)
        }
        return collector.result(.logs, extraDenied: denied)
    }

    // MARK: Trash

    static func trash(_ env: CleanupEnvironment, _ cancel: CleanupCancellation) -> CleanupCategoryResult {
        var collector = CleanupCollector(env: env, cancel: cancel)
        var denied = 0
        for root in [env.locations.trash] + env.volumeTrashRoots {
            let volume = root.path.hasPrefix("/Volumes/") ? root.pathComponents.dropFirst(2).first : nil
            for child in CleanupFS.children(of: root, denied: &denied) {
                collector.add(child, root: root, name: child.lastPathComponent,
                              detail: volume.map { "Trash on \($0)" }, isCache: false, inUseBy: nil,
                              keepsEmpty: true)
            }
        }
        return collector.result(.trash, extraDenied: denied)
    }
}

/// Validates, measures and accumulates candidates for one category.
struct CleanupCollector {
    let env: CleanupEnvironment
    let cancel: CleanupCancellation
    private let allowlist: [URL]
    private(set) var items: [CleanupItem] = []
    private(set) var denied = 0
    private var seen = Set<String>()

    init(env: CleanupEnvironment, cancel: CleanupCancellation) {
        self.env = env
        self.cancel = cancel
        self.allowlist = env.allowlist
    }

    /// Adds `url` if it passes the safety gate and takes up space. Returns the measured bytes, or nil if skipped.
    @discardableResult
    mutating func add(_ url: URL, root: URL, name: String, detail: String?, isCache: Bool, inUseBy: String?,
                      prefersSelected: Bool = true, note: String? = nil, lastActivity: Date? = nil,
                      minimumBytes: Int64 = 1, keepsEmpty: Bool = false) -> Int64? {
        guard !cancel.isCancelled, CleanupFS.exists(url) else { return nil }
        guard CleanupSafety.check(url, root: root, allowlist: allowlist, home: env.home) == nil else { return nil }
        let key = CleanupSafety.realPath(url) ?? url.path
        guard seen.insert(key).inserted else { return nil }
        let size = CleanupFS.measure(url, cancel: cancel)
        denied += size.denied
        guard size.bytes >= minimumBytes || keepsEmpty else { return nil }
        items.append(CleanupItem(url: url, root: root, name: name, detail: detail, bytes: size.bytes,
                                 lastActivity: lastActivity, isCache: isCache, inUseBy: inUseBy,
                                 prefersSelected: prefersSelected, note: note))
        return size.bytes
    }

    func result(_ category: CleanupCategoryID, extraDenied: Int = 0) -> CleanupCategoryResult {
        CleanupCategoryResult(category: category, items: items, deniedCount: denied + extraDenied)
    }
}
