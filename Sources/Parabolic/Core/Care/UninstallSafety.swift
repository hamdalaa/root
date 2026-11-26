import Foundation

/// The last line of defence before anything is moved to the Trash. Every check is on the path string,
/// so it is cheap and unit-testable.
enum UninstallSafety {
    static let scoopBundleID = "com.hamad.parabolic"

    /// Library folders whose *direct children* may be offered for removal.
    static func allowedParents(library: String) -> Set<String> {
        var parents = Set(UninstallFileKind.allCases.map { (library as NSString).appendingPathComponent($0.libraryFolder) })
        parents.insert((library as NSString).appendingPathComponent("Preferences/ByHost"))
        return parents
    }

    /// Folder and file names that are never offered, wherever they appear.
    private static let protectedNames: Set<String> = [
        "mobile documents", "mail", "messages", "keychains", "cloudstorage", "parabolic", "scoop",
        "photos", "music", "accounts", "safari", "addressbook", "calendars", "callhistorydb",
    ]

    private static let protectedPrefixes = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/", "/private/etc/"]

    /// True when the path must never be trashed.
    static func isProtected(path: String) -> Bool {
        let standardized = (path as NSString).standardizingPath
        if standardized == "/" || standardized.isEmpty { return true }
        if protectedPrefixes.contains(where: { standardized.hasPrefix($0) }) { return true }
        let lowered = standardized.lowercased()
        if lowered.contains(scoopBundleID) || lowered.contains(".photoslibrary") || lowered.contains(".musiclibrary") {
            return true
        }
        let name = (standardized as NSString).lastPathComponent.lowercased()
        if isAppleOwned(name) { return true }
        let stem = (name as NSString).deletingPathExtension
        return protectedNames.contains(name) || protectedNames.contains(stem)
    }

    /// Apple's own identifiers in any of the forms support folders use.
    static func isAppleOwned(_ name: String) -> Bool {
        let lowered = name.lowercased()
        let stripped = UninstallLeftovers.strippingPrefixes(name).lowercased()
        return stripped.hasPrefix("com.apple.") || stripped == "com.apple" || lowered.contains("com.apple.")
            || lowered.hasSuffix(".com.apple")
    }

    /// A support item is removable only if it is a direct child of a known ~/Library folder and not protected.
    static func isRemovableSupportItem(path: String, library: String) -> Bool {
        guard !isProtected(path: path) else { return false }
        let parent = ((path as NSString).standardizingPath as NSString).deletingLastPathComponent
        return allowedParents(library: (library as NSString).standardizingPath).contains(parent)
    }

    /// An app bundle may be trashed when it's a .app that isn't Apple's or Root.
    static func isRemovableApp(path: String, bundleID: String?) -> Bool {
        guard path.hasSuffix(".app"), !isProtected(path: path) else { return false }
        if let bundleID {
            let lowered = bundleID.lowercased()
            if lowered.hasPrefix("com.apple.") || lowered == scoopBundleID { return false }
        }
        if let main = Bundle.main.bundleIdentifier, main == bundleID { return false }
        return true
    }
}
