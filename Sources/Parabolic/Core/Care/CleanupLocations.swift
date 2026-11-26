import Foundation

/// Everything a scan depends on, injected so tests can point every scanner at a temp folder.
struct CleanupEnvironment: Sendable {
    var home: URL
    var now: Date
    var runningApps: [CleanupRunningApp]
    var projectRoots: [URL]
    /// Projects whose last activity is newer than this are left alone.
    var projectIdleDays: Int
    var oldDownloadDays: Int
    /// Disk images currently mounted (`hdiutil info`), by path.
    var mountedImagePaths: Set<String>
    /// Per-volume trash folders (`/Volumes/<name>/.Trashes/<uid>`).
    var volumeTrashRoots: [URL]
    /// Most recent time the user touched an item. Live: modified, added-to-folder and last-opened dates.
    var lastTouched: @Sendable (URL) -> Date?

    init(home: URL, now: Date = Date(), runningApps: [CleanupRunningApp] = [], projectRoots: [URL]? = nil,
         projectIdleDays: Int = 30, oldDownloadDays: Int = 90, mountedImagePaths: Set<String> = [],
         volumeTrashRoots: [URL] = [], lastTouched: @escaping @Sendable (URL) -> Date? = { CleanupFS.modificationDate($0) }) {
        self.home = home.standardizedFileURL
        self.now = now
        self.runningApps = runningApps
        self.projectRoots = projectRoots ?? CleanupLocations.defaultProjectRoots(home: home)
        self.projectIdleDays = projectIdleDays
        self.oldDownloadDays = oldDownloadDays
        self.mountedImagePaths = mountedImagePaths
        self.volumeTrashRoots = volumeTrashRoots
        self.lastTouched = lastTouched
    }

    var locations: CleanupLocations { CleanupLocations(home: home) }

    /// Every root Cleanup may remove things from. Items must sit strictly inside one of these.
    var allowlist: [URL] {
        let loc = locations
        var roots = [loc.caches, loc.logs, loc.diagnosticReports, loc.downloads, loc.desktop, loc.documents, loc.trash]
        roots += CleanupBrowser.all.flatMap { browser in
            browser.cacheSubpaths.map { home.appendingPathComponent($0) }
                + (browser.profileRootSubpath.map { [home.appendingPathComponent($0)] } ?? [])
        }
        roots += CleanupDevCache.all.map { $0.root(home: home) }
        roots += projectRoots
        roots += volumeTrashRoots
        return roots.map(\.standardizedFileURL)
    }

    /// The running app that owns `name` (a cache or log folder name), matched by bundle ID or app name.
    func runningOwner(ofFolderNamed name: String) -> String? {
        let lowered = name.lowercased()
        return runningApps.first { app in
            let id = app.bundleID.lowercased()
            return lowered == id || lowered.hasPrefix(id + ".") || lowered == app.name.lowercased()
        }?.name
    }

    func runningApp(withAnyOf bundleIDs: [String]) -> String? {
        let ids = Set(bundleIDs.map { $0.lowercased() })
        return runningApps.first { ids.contains($0.bundleID.lowercased()) }?.name
    }
}

/// Well-known folders under the home directory.
struct CleanupLocations: Sendable {
    let home: URL

    var library: URL { home.appendingPathComponent("Library") }
    var caches: URL { library.appendingPathComponent("Caches") }
    var logs: URL { library.appendingPathComponent("Logs") }
    var diagnosticReports: URL { logs.appendingPathComponent("DiagnosticReports") }
    var downloads: URL { home.appendingPathComponent("Downloads") }
    var desktop: URL { home.appendingPathComponent("Desktop") }
    var documents: URL { home.appendingPathComponent("Documents") }
    var trash: URL { home.appendingPathComponent(".Trash") }

    static func defaultProjectRoots(home: URL) -> [URL] {
        ["Desktop", "Developer", "Projects", "code", "src", "Sites", "Workspace", "GitHub", "Documents/GitHub"]
            .map { home.appendingPathComponent($0) }
    }

    /// Paths under ~/Library/Caches that a more specific category already owns, so App caches doesn't count them twice.
    var claimedCachePaths: Set<String> {
        let browser = CleanupBrowser.all.flatMap(\.cacheSubpaths)
        let developer = CleanupDevCache.all.map(\.subpath)
        return Set((browser + developer)
            .filter { $0.hasPrefix("Library/Caches/") }
            .map { home.appendingPathComponent($0).standardizedFileURL.path })
    }
}

/// A browser's cache-only folders. Profile data (cookies, history, logins, bookmarks) is never listed.
struct CleanupBrowser: Sendable {
    let name: String
    let bundleID: String
    /// Folders that are cache in their entirety, relative to home.
    let cacheSubpaths: [String]
    /// Chromium "User Data" folder, relative to home. Only named cache sub-folders inside it are cleaned.
    let profileRootSubpath: String?

    /// Chromium cache folders that live at the top of the User Data folder.
    static let chromiumRootCacheNames = ["ShaderCache", "GrShaderCache", "GraphiteDawnCache"]
    /// Chromium cache folders inside each profile (Default, Profile 1, …).
    static let chromiumProfileCacheNames = ["Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache",
                                            "DawnWebGPUCache", "Service Worker/ScriptCache"]

    static func isChromiumProfileName(_ name: String) -> Bool {
        name == "Default" || name.hasPrefix("Profile ") || name == "Guest Profile"
    }

    static let all: [CleanupBrowser] = [
        CleanupBrowser(name: "Safari", bundleID: "com.apple.Safari",
                       cacheSubpaths: ["Library/Caches/com.apple.Safari",
                                       "Library/Containers/com.apple.Safari/Data/Library/Caches"],
                       profileRootSubpath: nil),
        CleanupBrowser(name: "Google Chrome", bundleID: "com.google.Chrome",
                       cacheSubpaths: ["Library/Caches/Google/Chrome"],
                       profileRootSubpath: "Library/Application Support/Google/Chrome"),
        CleanupBrowser(name: "Arc", bundleID: "company.thebrowser.Browser",
                       cacheSubpaths: ["Library/Caches/Arc", "Library/Caches/company.thebrowser.Browser"],
                       profileRootSubpath: "Library/Application Support/Arc/User Data"),
        CleanupBrowser(name: "Brave", bundleID: "com.brave.Browser",
                       cacheSubpaths: ["Library/Caches/BraveSoftware/Brave-Browser"],
                       profileRootSubpath: "Library/Application Support/BraveSoftware/Brave-Browser"),
        CleanupBrowser(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac",
                       cacheSubpaths: ["Library/Caches/Microsoft Edge"],
                       profileRootSubpath: "Library/Application Support/Microsoft Edge"),
        CleanupBrowser(name: "Firefox", bundleID: "org.mozilla.firefox",
                       cacheSubpaths: ["Library/Caches/Firefox"],
                       profileRootSubpath: nil),
        CleanupBrowser(name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi",
                       cacheSubpaths: ["Library/Caches/Vivaldi", "Library/Caches/com.vivaldi.Vivaldi"],
                       profileRootSubpath: "Library/Application Support/Vivaldi"),
        CleanupBrowser(name: "Opera", bundleID: "com.operasoftware.Opera",
                       cacheSubpaths: ["Library/Caches/com.operasoftware.Opera"],
                       profileRootSubpath: "Library/Application Support/com.operasoftware.Opera"),
    ]
}

/// A developer tool cache: either one folder, or a folder whose children are listed one by one.
struct CleanupDevCache: Sendable {
    let name: String
    let subpath: String
    let listsChildren: Bool
    let isCache: Bool
    let ownerBundleIDs: [String]
    let prefersSelected: Bool
    let note: String?

    init(_ name: String, _ subpath: String, listsChildren: Bool = false, isCache: Bool = true,
         owners: [String] = [], prefersSelected: Bool = true, note: String? = nil) {
        self.name = name
        self.subpath = subpath
        self.listsChildren = listsChildren
        self.isCache = isCache
        self.ownerBundleIDs = owners
        self.prefersSelected = prefersSelected
        self.note = note
    }

    func folder(home: URL) -> URL { home.appendingPathComponent(subpath) }

    /// Listing caches are rooted at themselves; single-folder caches at their parent.
    func root(home: URL) -> URL {
        listsChildren ? folder(home: home) : folder(home: home).deletingLastPathComponent()
    }

    private static let xcode = ["com.apple.dt.Xcode"]

    static let all: [CleanupDevCache] = [
        CleanupDevCache("Xcode DerivedData", "Library/Developer/Xcode/DerivedData", listsChildren: true, owners: xcode),
        CleanupDevCache("iOS device support", "Library/Developer/Xcode/iOS DeviceSupport", listsChildren: true, owners: xcode),
        CleanupDevCache("watchOS device support", "Library/Developer/Xcode/watchOS DeviceSupport", listsChildren: true, owners: xcode),
        CleanupDevCache("tvOS device support", "Library/Developer/Xcode/tvOS DeviceSupport", listsChildren: true, owners: xcode),
        CleanupDevCache("visionOS device support", "Library/Developer/Xcode/visionOS DeviceSupport", listsChildren: true, owners: xcode),
        CleanupDevCache("Simulator caches", "Library/Developer/CoreSimulator/Caches",
                        owners: xcode + ["com.apple.iphonesimulator"]),
        CleanupDevCache("npm cache", ".npm/_cacache"),
        CleanupDevCache("Homebrew downloads", "Library/Caches/Homebrew"),
        CleanupDevCache("pip cache", "Library/Caches/pip"),
        CleanupDevCache("Yarn cache", "Library/Caches/Yarn"),
        CleanupDevCache("pnpm store", "Library/pnpm/store"),
        CleanupDevCache("Bun cache", ".bun/install/cache"),
        CleanupDevCache("Gradle caches", ".gradle/caches"),
        CleanupDevCache("CocoaPods cache", "Library/Caches/CocoaPods"),
        CleanupDevCache("Swift Package Manager cache", "Library/Caches/org.swift.swiftpm"),
        CleanupDevCache("Go build cache", "Library/Caches/go-build"),
        CleanupDevCache("Cargo download cache", ".cargo/registry/cache"),
        CleanupDevCache("Xcode Archives", "Library/Developer/Xcode/Archives", isCache: false, owners: xcode,
                        prefersSelected: false,
                        note: "Off by default: archives are needed to symbolicate crash reports and re-export builds."),
    ]
}

/// Display names derived from folder names.
enum CleanupNaming {
    /// "Parabolic-abcdefghijklmnopqrstuvwxyzab" → "Parabolic".
    static func derivedDataProject(_ folder: String) -> String {
        if folder == "ModuleCache.noindex" { return "Module cache" }
        guard let dash = folder.lastIndex(of: "-") else { return folder }
        let suffix = folder[folder.index(after: dash)...]
        guard suffix.count == 28, suffix.allSatisfy({ $0.isLowercase && $0.isLetter }) else { return folder }
        return String(folder[..<dash])
    }
}
