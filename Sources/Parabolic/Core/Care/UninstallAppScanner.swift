import CoreServices
import Foundation

/// Finds removable apps in every Applications folder, including ones on external drives.
enum UninstallAppScanner {
    /// A discovered bundle and the symlinks that point at it.
    struct Bundle: Equatable, Sendable {
        var url: URL
        var aliases: [URL]
    }

    /// /Applications, ~/Applications and every mounted /Volumes/*/Applications, deduplicated.
    static func defaultRoots(fileManager: FileManager = .default) -> [URL] {
        var roots = [URL(fileURLWithPath: "/Applications"),
                     fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        let volumes = (try? fileManager.contentsOfDirectory(atPath: "/Volumes")) ?? []
        for volume in volumes.sorted() where !volume.hasPrefix(".") {
            roots.append(URL(fileURLWithPath: "/Volumes").appendingPathComponent(volume).appendingPathComponent("Applications"))
        }
        return roots
    }

    /// Every .app directly in a root, or one folder down ("Adobe Photoshop 2026/Adobe Photoshop 2026.app").
    /// Symlinks are resolved and deduplicated by their real path; links that point at an app are kept as aliases.
    static func discoverBundles(roots: [URL], fileManager: FileManager = .default) -> [Bundle] {
        var byPath: [String: Bundle] = [:]
        var order: [String] = []
        var scannedRoots = Set<String>()

        func record(_ real: URL, alias: URL?) {
            let key = real.path
            if byPath[key] == nil {
                byPath[key] = Bundle(url: real, aliases: [])
                order.append(key)
            }
            if let alias, !(byPath[key]?.aliases.contains(alias) ?? false) { byPath[key]?.aliases.append(alias) }
        }

        func scan(_ folder: URL, depth: Int) {
            let children = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey],
                                                                 options: [.skipsHiddenFiles])) ?? []
            for child in children.sorted(by: { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }) {
                let isLink = (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
                let real = isLink ? child.resolvingSymlinksInPath() : child
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: real.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                if real.pathExtension.lowercased() == "app" {
                    record(real.standardizedFileURL, alias: isLink ? child : nil)
                } else if depth == 0 {
                    scan(real, depth: 1)
                }
            }
        }

        for root in roots {
            let real = root.resolvingSymlinksInPath().standardizedFileURL
            guard scannedRoots.insert(real.path).inserted else { continue }
            scan(real, depth: 0)
        }
        return order.compactMap { byPath[$0] }
    }

    /// Apple's apps, anything in /System, and Root itself are never offered.
    static func isExcluded(bundleID: String?, path: String) -> Bool {
        if path.hasPrefix("/System/") { return true }
        guard let bundleID else { return false }
        let lowered = bundleID.lowercased()
        return lowered.hasPrefix("com.apple.") || lowered == UninstallSafety.scoopBundleID
    }

    /// Reads one bundle's metadata. Nil for Apple apps, Root, and folders that aren't real bundles.
    static func loadApp(_ bundle: Bundle) -> UninstallApp? {
        let url = bundle.url
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        let info = (try? Data(contentsOf: infoURL)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        }
        let bundleID = info?["CFBundleIdentifier"] as? String
        guard !isExcluded(bundleID: bundleID, path: url.path),
              UninstallSafety.isRemovableApp(path: url.path, bundleID: bundleID) else { return nil }
        guard info != nil || FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents").path) else { return nil }

        let fileName = url.deletingPathExtension().lastPathComponent
        let displayName = (info?["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let bundleName = (info?["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let version = (info?["CFBundleShortVersionString"] as? String) ?? (info?["CFBundleVersion"] as? String)

        var volume = UninstallVolume.from(path: url.path)
        if case .startup = volume,
           let values = try? url.resourceValues(forKeys: [.volumeIsRootFileSystemKey, .volumeNameKey]),
           values.volumeIsRootFileSystem == false, let name = values.volumeName {
            volume = .external(name)
        }

        let owner = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.ownerAccountID] as? NSNumber
        let needsAdmin = owner.map { $0.uint32Value != getuid() } ?? false

        return UninstallApp(
            url: url,
            aliases: bundle.aliases,
            name: preferredName(fileName: fileName, displayName: displayName),
            bundleID: bundleID,
            bundleName: bundleName,
            version: version.flatMap { $0.isEmpty ? nil : $0 },
            volume: volume,
            isAppStore: FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path),
            lastUsed: lastUsedDate(url),
            needsAdmin: needsAdmin
        )
    }

    /// The Finder name usually reads best ("Visual Studio Code" rather than "Code").
    static func preferredName(fileName: String, displayName: String?) -> String {
        guard let displayName, displayName.count > fileName.count else { return fileName }
        return displayName
    }

    /// Spotlight's "Last opened" date. Nil when Spotlight has no record (never opened, or the volume isn't indexed).
    static func lastUsedDate(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// Full scan: discover, then read metadata. Sorted by name.
    static func scan(roots: [URL] = defaultRoots()) -> [UninstallApp] {
        discoverBundles(roots: roots)
            .compactMap(loadApp)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
