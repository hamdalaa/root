import Foundation

/// What a support item that is a symbolic link points at. Resolved exactly once — links are never followed further.
enum UninstallLinkTarget: Hashable, Sendable {
    /// Not a symlink: the item is the data.
    case none
    /// The link points at the same kind of Library folder on some volume (e.g. a drive the data was moved to).
    /// Link and target are handled as one item.
    case supportTarget(URL)
    /// The link points at nothing.
    case broken
    /// The link points somewhere unexpected; only the link itself is ever touched.
    case unexpected(URL)

    var target: URL? {
        if case .supportTarget(let url) = self { return url }
        return nil
    }

    var isLink: Bool { self != .none }
}

enum UninstallLinks {
    /// Library folders a moved support item may legitimately live in, on any volume.
    static let supportFolders: [String] = [
        "Caches", "Preferences", "Preferences/ByHost", "Application Support", "Containers", "Group Containers", "Logs",
        "Saved Application State", "HTTPStorages", "WebKit", "Cookies", "LaunchAgents", "Application Scripts",
    ]

    /// True when the path is a direct child of `<anything>/Library/<support folder>` and isn't protected.
    static func isEquivalentSupportLocation(_ path: String) -> Bool {
        let standardized = (path as NSString).standardizingPath
        guard standardized.hasPrefix("/"), !UninstallSafety.isProtected(path: standardized) else { return false }
        let parent = (standardized as NSString).deletingLastPathComponent
        return supportFolders.contains { parent.hasSuffix("/Library/" + $0) }
    }

    /// Reads the link once. A target that is itself a symlink counts as unexpected (no chains).
    static func resolve(_ url: URL, fileManager: FileManager = .default) -> UninstallLinkTarget {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeSymbolicLink else { return .none }
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else { return .broken }
        let absolute = destination.hasPrefix("/")
            ? destination
            : (url.deletingLastPathComponent().path as NSString).appendingPathComponent(destination)
        let target = URL(fileURLWithPath: absolute).standardizedFileURL
        guard let targetAttributes = try? fileManager.attributesOfItem(atPath: target.path) else { return .broken }
        if targetAttributes[.type] as? FileAttributeType == .typeSymbolicLink { return .unexpected(target) }
        // Same name and an equivalent folder: it's this item's data, moved.
        guard target.lastPathComponent == url.lastPathComponent, isEquivalentSupportLocation(target.path) else {
            return .unexpected(target)
        }
        return .supportTarget(target)
    }

    /// What to measure for an item: the target when it's moved data, nothing for broken/unexpected links.
    static func measureURL(for url: URL, link: UninstallLinkTarget) -> URL? {
        switch link {
        case .none: url
        case .supportTarget(let target): target
        case .broken, .unexpected: nil
        }
    }

    /// "on External" for data moved to another volume.
    static func volumeNote(_ link: UninstallLinkTarget) -> String? {
        guard let target = link.target else { return nil }
        if case .external(let name) = UninstallVolume.from(path: target.path) { return "on \(name)" }
        return "moved"
    }
}
