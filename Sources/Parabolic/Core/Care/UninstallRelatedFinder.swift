import Foundation

/// Finds an app's support files in ~/Library by bundle identifier, by name, by developer team and by launch agent target.
enum UninstallRelatedFinder {
    /// Everything about the other installed apps that's needed to tell shared files from this app's own.
    struct Context: Sendable {
        var otherBundleIDs: [String: String] = [:]   // lowercased id → app name
        var otherNames: [String: String] = [:]       // lowercased name → app name
        var otherVendors: [String: String] = [:]     // "com.vendor" → app name

        init(apps: [UninstallApp], excluding app: UninstallApp) {
            for other in apps where other.id != app.id {
                if let id = other.bundleID?.lowercased() { otherBundleIDs[id] = other.name }
                for name in other.nameCandidates { otherNames[name.lowercased()] = other.name }
                if let vendor = other.vendorPrefix { otherVendors[vendor] = other.name }
            }
        }

        init() {}
    }

    /// Suffixes support files add to a bundle ID ("com.x.app.plist", "com.x.app.savedState").
    private static let knownExtensions: Set<String> = ["plist", "savedstate", "binarycookies"]

    /// "com.x.app.binarycookies" → "com.x.app"; ByHost "com.x.app.0F3A….plist" → "com.x.app.0F3A…".
    static func stem(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        return knownExtensions.contains(ext) ? (name as NSString).deletingPathExtension : name
    }

    /// True when `name` (stripped of extension and container prefixes) is this ID or one of its sub-IDs.
    static func belongs(_ name: String, to bundleID: String) -> Bool {
        let candidate = UninstallLeftovers.strippingPrefixes(stem(name)).lowercased()
        let id = bundleID.lowercased()
        return candidate == id || candidate.hasPrefix(id + ".")
    }

    /// The other installed app a file name belongs to more specifically (com.x.app.pro vs com.x.app).
    static func moreSpecificOwner(_ name: String, than bundleID: String, context: Context) -> String? {
        let candidate = UninstallLeftovers.strippingPrefixes(stem(name)).lowercased()
        let id = bundleID.lowercased()
        return context.otherBundleIDs.first { other, _ in
            other.count > id.count && (candidate == other || candidate.hasPrefix(other + "."))
        }?.value
    }

    static func find(for app: UninstallApp, library: URL, context: Context, teamID: String?,
                     fileManager: FileManager = .default) -> [UninstallRelatedFile] {
        var results: [String: UninstallRelatedFile] = [:]
        func add(_ url: URL, _ kind: UninstallFileKind, _ match: UninstallMatch, shared: String?) {
            guard results[url.path] == nil,
                  UninstallSafety.isRemovableSupportItem(path: url.path, library: library.path) else { return }
            results[url.path] = UninstallRelatedFile(url: url, kind: kind, match: match, sharedWith: shared,
                                                     link: UninstallLinks.resolve(url, fileManager: fileManager))
        }
        func children(_ kind: UninstallFileKind, subfolder: String? = nil) -> [URL] {
            var folder = library.appendingPathComponent(kind.libraryFolder)
            if let subfolder { folder.appendPathComponent(subfolder) }
            // Name-based listing keeps dangling symlinks, which URL-based listing can drop.
            return ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []).map { folder.appendingPathComponent($0) }
        }

        let idKinds: [UninstallFileKind] = [.appSupport, .caches, .preferences, .containers, .groupContainers, .savedState,
                                             .httpStorage, .webKit, .logs, .cookies, .appScripts]
        if let bundleID = app.bundleID {
            let sharedByID = context.otherBundleIDs[bundleID.lowercased()]
            for kind in idKinds {
                var urls = children(kind)
                if kind == .preferences { urls += children(kind, subfolder: "ByHost") }
                for url in urls where belongs(url.lastPathComponent, to: bundleID) {
                    guard moreSpecificOwner(url.lastPathComponent, than: bundleID, context: context) == nil else { continue }
                    add(url, kind, .bundleID, shared: sharedByID)
                }
            }
        }

        // Developer-team group containers ("UBF8T346G9.Office"): shared when another app from the same vendor is installed.
        if let teamID, teamID.count == 10 {
            let sharedVendor = app.vendorPrefix.flatMap { context.otherVendors[$0] }
            for url in children(.groupContainers) where url.lastPathComponent.hasPrefix(teamID + ".") {
                add(url, .groupContainers, .developerTeam, shared: sharedVendor ?? (app.vendorPrefix == nil ? "other apps from this developer" : nil))
            }
        }

        // Exact-name folders ("Application Support/Blender").
        for name in app.nameCandidates where name.count >= 4 {
            let shared = context.otherNames[name.lowercased()]
            for kind in [UninstallFileKind.appSupport, .caches, .logs] {
                let url = library.appendingPathComponent(kind.libraryFolder).appendingPathComponent(name)
                if fileManager.fileExists(atPath: url.path) || isSymlink(url) { add(url, kind, .name, shared: shared) }
            }
        }

        // LaunchAgents that run something inside the app, or carry its bundle ID as a label.
        let appPaths = [app.url.path] + app.aliases.map(\.path)
        for url in children(.launchAgent) where url.pathExtension == "plist" {
            guard let data = fileManager.contents(atPath: url.path), let plist = try? LoginItemPlist.parse(data: data) else { continue }
            let pointsInside = ([plist.program].compactMap { $0 } + plist.arguments).contains { argument in
                appPaths.contains { mentions(argument, path: $0) }
            }
            let labelMatches = app.bundleID.map { id in plist.label.map { belongs($0, to: id) } ?? false } ?? false
            if pointsInside || labelMatches { add(url, .launchAgent, pointsInside ? .launchAgentTarget : .bundleID, shared: nil) }
        }

        return results.values.sorted {
            $0.kind.rawValue == $1.kind.rawValue ? $0.url.lastPathComponent < $1.url.lastPathComponent
                : UninstallFileKind.allCases.firstIndex(of: $0.kind)! < UninstallFileKind.allCases.firstIndex(of: $1.kind)!
        }
    }

    /// True when the argument is the path, or contains it followed by a path or quote boundary.
    static func mentions(_ argument: String, path: String) -> Bool {
        if argument == path { return true }
        for boundary in ["/", "'", "\"", " ", ";"] where argument.contains(path + boundary) { return true }
        return argument.hasSuffix(path)
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
    }
}
