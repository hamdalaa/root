import Foundation

/// Whether an extension is installed and on in a Chromium browser, read from the profile's preference files.
enum BrowserExtensionState: Int, Comparable, Sendable {
    case notInstalled, disabled, enabled

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The most-installed state across profiles: one profile with it on is enough.
    static func best(_ states: [Self]) -> Self { states.max() ?? .notInstalled }
}

/// Reads `extensions.settings.<id>` from Chromium's `Secure Preferences` and `Preferences`.
/// Read-only: the browser owns these files and rewrites them while running.
enum BrowserExtensionReader {
    private static let preferenceFiles = ["Secure Preferences", "Preferences"]

    /// `extensions.settings` of each preference file, parsed once (the files are megabytes).
    static func extensionSettings(_ preferences: [Data]) -> [[String: Any]] {
        preferences.compactMap { data in
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let extensions = root["extensions"] as? [String: Any] else { return nil }
            return extensions["settings"] as? [String: Any]
        }
    }

    /// Entries for `id` from every file, merged (later files fill in or override keys).
    private static func entry(for id: String, settings: [[String: Any]]) -> [String: Any] {
        var merged: [String: Any] = [:]
        for file in settings {
            guard let entry = file[id] as? [String: Any] else { continue }
            merged.merge(entry) { _, new in new }
        }
        return merged
    }

    static func state(of id: String, preferences: [Data]) -> BrowserExtensionState {
        state(of: id, settings: extensionSettings(preferences))
    }

    /// An empty entry is what Chromium leaves behind after an unpacked extension's folder disappears.
    static func state(of id: String, settings: [[String: Any]]) -> BrowserExtensionState {
        let entry = entry(for: id, settings: settings)
        guard entry["path"] != nil || entry["manifest"] != nil else { return .notInstalled }
        if let reasons = entry["disable_reasons"] as? [Any], !reasons.isEmpty { return .disabled }
        if let bitmask = entry["disable_reasons"] as? Int, bitmask != 0 { return .disabled }
        if let state = entry["state"] as? Int, state == 0 { return .disabled }
        return .enabled
    }

    /// Folder an unpacked (location 4) extension loads from.
    static func unpackedPath(of id: String, preferences: [Data]) -> String? {
        let entry = entry(for: id, settings: extensionSettings(preferences))
        guard let path = entry["path"] as? String, path.hasPrefix("/") else { return nil }
        return path
    }

    /// Profile folders under a browser's user-data root: "Default" and "Profile N".
    static func profiles(in profileRoot: String) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: profileRoot) else { return [] }
        return names
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
            .map { (profileRoot as NSString).appendingPathComponent($0) }
            .filter { profile in preferenceFiles.contains { fm.fileExists(atPath: (profile as NSString).appendingPathComponent($0)) } }
    }

    static func preferenceData(inProfile profile: String) -> [Data] {
        preferenceFiles.compactMap { FileManager.default.contents(atPath: (profile as NSString).appendingPathComponent($0)) }
    }

    /// Parsed extension settings of every profile of a browser.
    static func profileSettings(profileRoot: String) -> [[[String: Any]]] {
        profiles(in: profileRoot).map { extensionSettings(preferenceData(inProfile: $0)) }
    }
}

/// Other download managers whose browser extensions grab the same downloads Root catches.
enum RivalCatcher {
    struct Known: Sendable {
        let name: String
        let extensionIDs: [String]
    }

    static let known: [Known] = [
        Known(name: "Free Download Manager", extensionIDs: ["ahmpjcflkgiildlgicmcieglgoilbfdp", "mdfcjfioplkdchnhcpcobaheocanedjg"]),
        Known(name: "Internet Download Manager", extensionIDs: ["ngpampappnmepgilojfohadhhmbhlaek"]),
    ]

    /// Names of rival extensions that are on in any of these profiles.
    static func enabled(inProfiles profiles: [[[String: Any]]]) -> [String] {
        known.filter { rival in
            rival.extensionIDs.contains { id in
                profiles.contains { BrowserExtensionReader.state(of: id, settings: $0) == .enabled }
            }
        }.map(\.name)
    }
}

/// Everything Settings needs to know about one browser, read off the main thread.
struct BrowserStatus: Identifiable, Sendable {
    let browser: BrowserBridge.Browser
    /// Native-messaging manifest present (the extension can reach Root).
    let isConnected: Bool
    /// Root's extension in this browser. Nil for Firefox (its add-on state isn't readable here).
    let rootExtension: BrowserExtensionState?
    /// "Free Download Manager" etc., when their extension is on.
    let rivals: [String]

    var id: String { browser.id }

    static func read(_ browser: BrowserBridge.Browser) -> BrowserStatus {
        guard !browser.isFirefox else {
            return BrowserStatus(browser: browser, isConnected: browser.isConnected, rootExtension: nil, rivals: [])
        }
        let profiles = BrowserExtensionReader.profileSettings(profileRoot: browser.profileRoot)
        let root = BrowserExtensionState.best(profiles.map {
            BrowserExtensionReader.state(of: BrowserBridge.chromeExtensionID, settings: $0)
        })
        return BrowserStatus(browser: browser, isConnected: browser.isConnected, rootExtension: root,
                             rivals: RivalCatcher.enabled(inProfiles: profiles))
    }

    static func readAll() -> [BrowserStatus] {
        BrowserBridge.browsers.filter(\.isInstalled).map(read)
    }
}
