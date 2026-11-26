import AppKit
import Darwin
import Foundation

/// What Storage is allowed to move to the Trash, and the act of doing it.
enum StorageSafety {
    /// Why an item can't be trashed from Storage, or nil when it can.
    static func protectionReason(for url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let path = normalized(url.path)
        let home = normalized(home.path)

        if path == "/" || path.isEmpty { return "This is the startup disk." }
        if isVolumeRoot(path) { return "This is the top of a disk." }
        for root in systemRoots where path == root || path.hasPrefix(root + "/") {
            return "Part of macOS."
        }
        if path.hasPrefix("/usr/"), !(path == "/usr/local" || path.hasPrefix("/usr/local/")) { return "Part of macOS." }
        if path == "/usr" { return "Part of macOS." }

        if path == home { return "This is your home folder." }
        if topLevelSystemFolders.contains(path) { return "A system folder." }
        // Home's top-level standard folders themselves (their contents are fine).
        for name in standardHomeFolders where path == home + "/" + name {
            return "A standard folder in your home."
        }
        for suffix in protectedHomePaths {
            let protected = home + "/" + suffix
            if path == protected || path.hasPrefix(protected + "/") { return "Managed by macOS or another app." }
            // A folder that holds protected data (e.g. ~/Library/Application Support holds Root's own data).
            if protected.hasPrefix(path + "/") { return "Contains data managed by macOS or Root." }
        }
        // Photos, Music, TV and Aperture libraries anywhere.
        let components = path.lowercased().split(separator: "/")
        if components.contains(where: { part in libraryPackageExtensions.contains { part.hasSuffix(".\($0)") } }) {
            return "A Photos, Music or TV library."
        }
        if path == home + "/Music/Music" || path.hasPrefix(home + "/Music/Music/") { return "Inside your Music library." }
        return nil
    }

    static func canTrash(_ url: URL) -> Bool { protectionReason(for: url) == nil }

    /// Moves items to the Trash one by one (never deletes). Returns the URLs that failed with a reason.
    static func trash(_ urls: [URL]) async -> [(URL, String)] {
        await Task.detached(priority: .userInitiated) {
            var failures: [(URL, String)] = []
            for url in urls {
                if let reason = protectionReason(for: url) { failures.append((url, reason)); continue }
                do {
                    // trashItem moves a symlink itself, never its target.
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                } catch {
                    failures.append((url, error.localizedDescription))
                }
            }
            return failures
        }.value
    }

    /// Probes a TCC-protected file without triggering a consent prompt. True when Full Disk Access is granted.
    static func hasFullDiskAccess() -> Bool {
        let probe = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path
        let fd = open(probe, O_RDONLY)
        if fd >= 0 { close(fd); return true }
        // ENOENT means we can't tell; don't nag in that case.
        return errno != EPERM && errno != EACCES
    }

    static let fullDiskAccessURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    @MainActor static func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(fullDiskAccessURL)
    }

    // MARK: Rules

    private static let systemRoots = ["/System", "/bin", "/sbin", "/private/var/db", "/private/var/vm", "/var/db", "/var/vm",
                                      "/cores", "/dev", "/Library/Apple"]
    private static let topLevelSystemFolders: Set<String> = ["/Users", "/Applications", "/Library", "/Volumes", "/private",
                                                             "/etc", "/var", "/tmp", "/opt", "/usr/local"]
    private static let standardHomeFolders = ["Applications", "Desktop", "Documents", "Downloads", "Library", "Movies",
                                              "Music", "Pictures", "Public", "Sites", ".Trash"]
    private static let protectedHomePaths = [
        "Library/Mobile Documents", "Library/Mail", "Library/Messages", "Library/Keychains",
        "Library/Application Support/Parabolic", "Library/Containers/com.apple.mail",
        "Library/Group Containers/group.com.apple.notes", "Library/CloudStorage",
        "Library/Application Support/AddressBook", "Library/Calendars", "Library/Safari",
    ]
    private static let libraryPackageExtensions = ["photoslibrary", "musiclibrary", "tvlibrary", "aplibrary", "photolibrary"]

    private static func normalized(_ path: String) -> String {
        var path = (path as NSString).standardizingPath
        if path.hasPrefix("/System/Volumes/Data/") { path = String(path.dropFirst("/System/Volumes/Data".count)) }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static func isVolumeRoot(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        return parts.count == 2 && parts[0] == "Volumes"
    }
}
