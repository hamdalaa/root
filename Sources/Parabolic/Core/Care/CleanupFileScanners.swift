import Foundation

/// Installers and old downloads: the user's own files, judged by type and by age.
enum CleanupFileScanners {
    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "xip", "iso"]
    /// Partial downloads from browsers and download managers; never offered as "old".
    static let partialExtensions: Set<String> = ["crdownload", "download", "part", "opdownload", "partial", "aria2"]
    static let installerDepth = 2

    // MARK: Installers

    static func installers(_ env: CleanupEnvironment, _ cancel: CleanupCancellation) -> CleanupCategoryResult {
        let loc = env.locations
        var collector = CleanupCollector(env: env, cancel: cancel)
        var denied = 0
        let roots: [(URL, String)] = [(loc.downloads, "Downloads"), (loc.desktop, "Desktop"), (loc.documents, "Documents")]
        for (root, label) in roots {
            walkInstallers(root, root: root, label: label, depth: 0, env: env, collector: &collector,
                           denied: &denied, cancel: cancel)
        }
        return collector.result(.installers, extraDenied: denied)
    }

    private static func walkInstallers(_ folder: URL, root: URL, label: String, depth: Int, env: CleanupEnvironment,
                                       collector: inout CleanupCollector, denied: inout Int, cancel: CleanupCancellation) {
        guard depth <= installerDepth, !cancel.isCancelled else { return }
        for child in CleanupFS.children(of: folder, denied: &denied) {
            let name = child.lastPathComponent
            if name.hasPrefix(".") || CleanupFS.isSymlink(child) { continue }
            if isInstaller(child) {
                let place = depth == 0 ? label : "\(label) › \(folder.lastPathComponent)"
                let mounted = env.mountedImagePaths.contains(child.standardizedFileURL.path)
                let inDownloads = label == "Downloads"
                let note: String? = mounted ? "Mounted right now. Eject it before cleaning."
                    : inDownloads ? nil : "Off by default: outside Downloads, so it may be kept on purpose."
                collector.add(child, root: root, name: name, detail: place, isCache: false, inUseBy: nil,
                              prefersSelected: inDownloads && !mounted, note: note,
                              lastActivity: env.lastTouched(child))
                continue
            }
            guard CleanupFS.isDirectory(child), !isPackageLike(name),
                  !CleanupProjectScanner.artifacts.contains(where: { $0.folder == name }) else { continue }
            walkInstallers(child, root: root, label: label, depth: depth + 1, env: env, collector: &collector,
                           denied: &denied, cancel: cancel)
        }
    }

    /// Disk images, packages (flat or bundle), Xcode .xip, ISO images, and zips whose contents are an app or installer.
    static func isInstaller(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if installerExtensions.contains(ext) {
            return ext == "pkg" || ext == "mpkg" ? true : CleanupFS.isRegularFile(url)
        }
        if ext == "zip", CleanupFS.isRegularFile(url) { return CleanupFS.zipContainsInstaller(url) }
        return false
    }

    private static func isPackageLike(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return [".app", ".bundle", ".framework", ".photoslibrary", ".xcodeproj", ".xcworkspace", ".pkg", ".mpkg"]
            .contains { lowered.hasSuffix($0) }
    }

    // MARK: Old downloads

    static func oldDownloads(_ env: CleanupEnvironment, _ cancel: CleanupCancellation) -> CleanupCategoryResult {
        let root = env.locations.downloads
        var collector = CleanupCollector(env: env, cancel: cancel)
        var denied = 0
        let cutoff = env.now.addingTimeInterval(-Double(env.oldDownloadDays) * 86_400)
        for child in CleanupFS.children(of: root, denied: &denied) {
            if cancel.isCancelled { break }
            let name = child.lastPathComponent
            guard !name.hasPrefix("."), !partialExtensions.contains(child.pathExtension.lowercased()),
                  !isInstaller(child), let touched = env.lastTouched(child), touched < cutoff else { continue }
            collector.add(child, root: root, name: name, detail: nil, isCache: false, inUseBy: nil,
                          lastActivity: touched)
        }
        return collector.result(.oldDownloads, extraDenied: denied)
    }
}
