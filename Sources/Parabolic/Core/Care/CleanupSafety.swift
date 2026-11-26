import Darwin
import Foundation

/// Why a path was refused. Shown when a clean skips something.
enum CleanupRejection: Equatable, Sendable {
    case missing
    case symlink
    case notAllowlisted
    case escapesRoot
    case protectedLocation
    case lockedBySystem

    var reason: String {
        switch self {
        case .missing: "It no longer exists"
        case .symlink: "It’s a symbolic link"
        case .notAllowlisted: "It isn’t in a folder Cleanup is allowed to touch"
        case .escapesRoot: "Its real location is outside the scanned folder"
        case .protectedLocation: "It’s in a protected location"
        case .lockedBySystem: "macOS protects it"
        }
    }
}

/// The single gate every scan result and every removal goes through.
///
/// Rules: the item must exist, must not itself be a symlink, its fully resolved path must sit strictly inside an
/// allowlisted root (so links in parent folders can't redirect it), and neither path may be a protected location.
enum CleanupSafety {
    /// System locations Cleanup never touches, whatever the allowlist says.
    static let systemPrefixes = [
        "/System", "/bin", "/sbin", "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/libexec", "/usr/share",
        "/private/var/db", "/private/var/protected", "/Library/Apple", "/Applications", "/private/etc", "/cores",
    ]

    /// Personal data inside the home folder that must never be cleaned, relative to `home`.
    static let protectedHomeSubpaths = [
        "Library/Mobile Documents", "Library/Mail", "Library/Messages", "Library/Keychains",
        "Library/Containers/com.apple.mail", "Library/Containers/com.apple.MobileSMS",
        "Library/Application Support/Parabolic", "Library/Application Support/AddressBook",
        "Library/Calendars", "Library/Cookies", "Library/Accounts", "Library/Safari",
        "Library/Group Containers", "Library/Photos", "Pictures/Photos Library.photoslibrary", "Music/Music",
    ]

    /// Bundle-like folders (libraries, apps) that are never cleaned or cleaned inside.
    static let protectedSuffixes = [".photoslibrary", ".musiclibrary", ".tvlibrary", ".photolibrary", ".aplibrary",
                                    ".app", ".keychain", ".keychain-db"]

    /// Root's own bundle identifiers; their caches and logs are off limits.
    static let ownBundleIDs: Set<String> = {
        var ids: Set<String> = ["com.hamad.parabolic"]
        if let id = Bundle.main.bundleIdentifier { ids.insert(id) }
        return ids
    }()

    /// Validates `url` against `root` and the allowlist.
    static func check(_ url: URL, root: URL, allowlist: [URL], home: URL) -> CleanupRejection? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return .missing }
        if (info.st_mode & S_IFMT) == S_IFLNK { return .symlink }
        let lockedFlags = UInt32(SF_RESTRICTED) | UInt32(SF_IMMUTABLE) | UInt32(UF_IMMUTABLE)
        if info.st_flags & lockedFlags != 0 { return .lockedBySystem }

        guard let realRoot = realPath(root) else { return .notAllowlisted }
        let realAllowlist = allowlist.compactMap(realPath)
        guard realAllowlist.contains(realRoot) else { return .notAllowlisted }
        guard let realItem = realPath(url) else { return .missing }
        guard isStrictlyInside(realItem, realRoot) else { return .escapesRoot }

        let realHome = realPath(home) ?? home.standardizedFileURL.path
        if isProtected(realItem, home: realHome) || isProtected(url.standardizedFileURL.path, home: home.standardizedFileURL.path) {
            return .protectedLocation
        }
        return nil
    }

    static func isProtected(_ path: String, home: String) -> Bool {
        if systemPrefixes.contains(where: { isInsideOrEqual(path, $0) }) { return true }
        if protectedHomeSubpaths.contains(where: { isInsideOrEqual(path, home + "/" + $0) }) { return true }
        for id in ownBundleIDs {
            if isInsideOrEqual(path, home + "/Library/Caches/" + id) { return true }
            if isInsideOrEqual(path, home + "/Library/Logs/" + id) { return true }
        }
        var prefix = ""
        for component in path.split(separator: "/") {
            prefix += "/" + component
            let name = component.lowercased()
            guard let suffix = protectedSuffixes.first(where: { name.hasSuffix($0) }) else { continue }
            // Bundle-ID folders like "com.example.App" end in ".app" too; only a real bundle counts.
            if suffix != ".app" || isAppBundle(prefix) { return true }
        }
        return false
    }

    /// True when `path` is an app bundle on disk (macOS or wrapped iOS layout).
    static func isAppBundle(_ path: String) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: path + "/Contents/Info.plist") || fm.fileExists(atPath: path + "/Info.plist")
            || fm.fileExists(atPath: path + "/Wrapper")
    }

    /// Canonical absolute path with every symlink resolved, or nil if it doesn't exist.
    static func realPath(_ url: URL) -> String? {
        guard let resolved = Darwin.realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func isStrictlyInside(_ path: String, _ root: String) -> Bool {
        let base = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(base) && path.count > base.count
    }

    static func isInsideOrEqual(_ path: String, _ root: String) -> Bool {
        path == root || isStrictlyInside(path, root)
    }
}
