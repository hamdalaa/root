import Foundation

/// Where an app bundle lives: the startup disk or a named external volume.
enum UninstallVolume: Hashable, Sendable {
    case startup
    case external(String)

    var title: String {
        switch self {
        case .startup: "Internal"
        case .external(let name): name
        }
    }

    var isExternal: Bool { if case .external = self { true } else { false } }

    /// Path-based guess: anything under /Volumes/<name>/ is on that volume.
    static func from(path: String) -> UninstallVolume {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Volumes" else { return .startup }
        let name = String(parts[1])
        return name == "Macintosh HD" ? .startup : .external(name)
    }
}

/// One installed, removable app.
struct UninstallApp: Identifiable, Hashable, Sendable {
    /// The resolved bundle path; stable across rescans.
    var id: String { url.path }
    /// The real bundle (symlinks resolved).
    let url: URL
    /// Symlinks in a scanned Applications folder that point at this bundle.
    let aliases: [URL]
    let name: String
    let bundleID: String?
    let bundleName: String?
    let version: String?
    let volume: UninstallVolume
    let isAppStore: Bool
    let lastUsed: Date?
    /// Owned by another user (usually root): macOS asks for a password to move it.
    let needsAdmin: Bool

    /// Names that support folders are commonly called, longest-lived first.
    var nameCandidates: [String] {
        var seen = Set<String>()
        return [name, bundleName, url.deletingPathExtension().lastPathComponent]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { UninstallNames.isUsable($0) && seen.insert($0.lowercased()).inserted }
    }

    /// "com.vendor" — used to spot files shared between apps from the same developer.
    var vendorPrefix: String? { bundleID.flatMap(UninstallNames.vendorPrefix) }
}

/// What kind of support file a related item is.
enum UninstallFileKind: String, Sendable, CaseIterable {
    case appSupport, caches, preferences, containers, groupContainers, savedState
    case httpStorage, webKit, logs, cookies, appScripts, launchAgent

    var title: String {
        switch self {
        case .appSupport: "Application Support"
        case .caches: "Caches"
        case .preferences: "Preferences"
        case .containers: "Container"
        case .groupContainers: "Group Container"
        case .savedState: "Saved Window State"
        case .httpStorage: "HTTP Storage"
        case .webKit: "Web Data"
        case .logs: "Logs"
        case .cookies: "Cookies"
        case .appScripts: "Application Scripts"
        case .launchAgent: "Background Item"
        }
    }

    var symbol: String {
        switch self {
        case .appSupport: "folder"
        case .caches: "archivebox"
        case .preferences: "slider.horizontal.3"
        case .containers, .groupContainers: "shippingbox"
        case .savedState: "macwindow"
        case .httpStorage, .cookies: "network"
        case .webKit: "globe"
        case .logs: "doc.text"
        case .appScripts: "applescript"
        case .launchAgent: "gearshape.2"
        }
    }

    /// Folder under ~/Library this kind lives in.
    var libraryFolder: String {
        switch self {
        case .appSupport: "Application Support"
        case .caches: "Caches"
        case .preferences: "Preferences"
        case .containers: "Containers"
        case .groupContainers: "Group Containers"
        case .savedState: "Saved Application State"
        case .httpStorage: "HTTPStorages"
        case .webKit: "WebKit"
        case .logs: "Logs"
        case .cookies: "Cookies"
        case .appScripts: "Application Scripts"
        case .launchAgent: "LaunchAgents"
        }
    }
}

/// How a related file was tied to the app.
enum UninstallMatch: Sendable, Hashable {
    case bundleID
    case name
    case developerTeam
    case launchAgentTarget

    var note: String {
        switch self {
        case .bundleID: "Matched by bundle identifier"
        case .name: "Matched by app name"
        case .developerTeam: "Matched by developer team"
        case .launchAgentTarget: "Runs a program inside the app"
        }
    }
}

/// A support file found for an app.
struct UninstallRelatedFile: Identifiable, Hashable, Sendable {
    var id: String { url.path }
    let url: URL
    let kind: UninstallFileKind
    let match: UninstallMatch
    /// Another installed app probably uses this too, so it isn't selected by default.
    let sharedWith: String?
    /// Set when the item is a symlink (e.g. data moved to an external drive).
    var link: UninstallLinkTarget = .none

    /// What to measure: the moved data for support links, nothing for broken or unexpected links.
    var measureURL: URL? { UninstallLinks.measureURL(for: url, link: link) }
}

/// Shared name helpers.
enum UninstallNames {
    private static let generic: Set<String> = [
        "electron", "google", "adobe", "microsoft", "apple", "helper", "caches", "logs", "data", "default",
        "shared", "library", "application", "applications", "updater", "update", "app", "apps", "settings",
        "preferences", "support", "cache", "temp", "tmp", "crashpad", "plugins", "cloudkit", "metadata",
    ]

    /// At least 3 characters and not a word many apps use for unrelated folders.
    static func isUsable(_ name: String) -> Bool {
        name.count >= 3 && !generic.contains(name.lowercased())
    }

    /// "com.vendor.app" → "com.vendor".
    static func vendorPrefix(_ bundleID: String) -> String? {
        let parts = bundleID.lowercased().split(separator: ".")
        guard parts.count >= 3 else { return nil }
        return parts.prefix(2).joined(separator: ".")
    }
}
