import Foundation

/// One support item left behind by an app that's no longer installed.
struct UninstallLeftoverItem: Identifiable, Hashable, Sendable {
    var id: String { url.path }
    let url: URL
    let kind: UninstallFileKind
    var bytes: Int64?
    var newest: Date?
    var link: UninstallLinkTarget = .none

    var measureURL: URL? { UninstallLinks.measureURL(for: url, link: link) }
}

/// Support items grouped by the app that probably made them.
struct UninstallLeftoverGroup: Identifiable, Hashable, Sendable {
    /// Canonical "com.vendor.app".
    let id: String
    let displayName: String
    let vendor: String
    var items: [UninstallLeftoverItem]

    var bytes: Int64 { items.reduce(0) { $0 + ($1.bytes ?? 0) } }
    var newest: Date? { items.compactMap(\.newest).max() }
}

/// Finds support files whose bundle-ID-shaped names match nothing installed. Conservative by design:
/// Apple's items, anything a same-vendor app could still use, and anything changed recently are skipped.
enum UninstallLeftovers {
    /// Items touched more recently than this are probably still in use.
    static let quietPeriod: TimeInterval = 30 * 24 * 3600

    private static let teamPrefix = try! NSRegularExpression(pattern: "^[a-z0-9]{10}\\.", options: [.caseInsensitive])
    private static let byHostSuffix = try! NSRegularExpression(
        pattern: "\\.[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", options: [.caseInsensitive])
    private static let bundleShape = try! NSRegularExpression(
        pattern: "^[a-z]{2,6}(\\.[a-z0-9][a-z0-9_-]*){2,}$", options: [.caseInsensitive])

    /// Strips "group.", "systemgroup." and a 10-character team ID ("UBF8T346G9.") from a container name.
    static func strippingPrefixes(_ name: String) -> String {
        var result = name
        let range = NSRange(result.startIndex..., in: result)
        if let match = teamPrefix.firstMatch(in: result, range: range), let swiftRange = Range(match.range, in: result),
           result[swiftRange].dropLast().contains(where: { $0.isUppercase || $0.isNumber }) {
            result.removeSubrange(swiftRange)
        }
        for prefix in ["systemgroup.", "groups.", "group."] where result.lowercased().hasPrefix(prefix) {
            result.removeFirst(prefix.count)
        }
        return result
    }

    /// The bundle ID a support item is named after, lowercased; nil if the name isn't bundle-ID-shaped.
    static func canonicalID(fromEntryName name: String) -> String? {
        var value = UninstallRelatedFinder.stem(name)
        let range = NSRange(value.startIndex..., in: value)
        if let match = byHostSuffix.firstMatch(in: value, range: range), let swiftRange = Range(match.range, in: value) {
            value.removeSubrange(swiftRange)
        }
        value = strippingPrefixes(value)
        let lowered = value.lowercased()
        guard bundleShape.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)) != nil else { return nil }
        // The first component must be a lowercase domain ending (rules out "Adobe.backup-2026…", "AI.Chat.Foo", "main.kts…").
        guard let first = value.split(separator: ".").first, first == first.lowercased(),
              domainEndings.contains(String(first)) else { return nil }
        return lowered
    }

    /// "com.vendor.app.helper" → "com.vendor.app": items are grouped under the first three components.
    static func groupKey(_ canonical: String) -> String {
        canonical.split(separator: ".").prefix(3).joined(separator: ".")
    }

    /// What's installed, normalised for matching.
    struct Index: Sendable {
        var bundleIDs: Set<String> = []
        var vendors: Set<String> = []
        var names: Set<String> = []

        init(bundleIDs: [String], names: [String]) {
            for id in bundleIDs.map({ $0.lowercased() }) {
                self.bundleIDs.insert(id)
                if let vendor = UninstallNames.vendorPrefix(id) { vendors.insert(vendor) }
            }
            self.names = Set(names.map(UninstallLeftovers.normalized).filter { $0.count >= 4 })
        }
    }

    enum Verdict: Equatable, Sendable {
        case installed
        /// Could belong to something still here (same vendor, same name, a command-line tool).
        case ambiguous
        case orphan
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static let domainEndings: Set<String> = [
        "com", "org", "net", "io", "ai", "app", "dev", "co", "me", "de", "uk", "fr", "jp", "cn", "ru", "is", "tv", "us",
        "ca", "nl", "se", "ch", "it", "es", "info", "biz", "xyz", "so", "sh", "cc", "ly", "gg", "to", "fm", "im", "pro",
        "design", "studio", "tech", "cloud", "page", "games", "eu", "at", "be", "pl", "kr", "in", "au", "br", "edu", "cz",
    ]

    /// SDKs and toolchains whose folders many apps (or command-line tools) share.
    private static let sharedVendors: Set<String> = [
        "crashlytics", "firebase", "google", "facebook", "microsoft", "sparkle", "squirrel", "electron", "github",
        "segment", "sentry", "amplitude", "mixpanel", "bugsnag", "android", "chromium", "mozilla", "apple", "jetbrains",
        "npmjs", "nodejs", "workflow", "python", "docker", "brew", "homebrew", "vscode", "unity3d", "adobe",
    ]

    private static let toolWords: Set<String> = ["cli", "daemon", "agent", "service", "server", "tool", "tools", "sdk"]

    /// Classifies a canonical (lowercased) bundle ID against what's installed.
    static func classify(_ id: String, index: Index, isKnownApp: (String) -> Bool = { _ in false }) -> Verdict {
        if index.bundleIDs.contains(id) { return .installed }
        if index.bundleIDs.contains(where: { id.hasPrefix($0 + ".") || $0.hasPrefix(id + ".") }) { return .installed }
        if isKnownApp(id) { return .installed }
        if let vendor = UninstallNames.vendorPrefix(id), index.vendors.contains(vendor) { return .ambiguous }
        let parts = id.split(separator: ".").map(String.init)
        if parts.count >= 2, sharedVendors.contains(parts[1]) { return .ambiguous }
        if parts.dropFirst(2).contains(where: { toolWords.contains($0) }) { return .ambiguous }
        if parts.dropFirst(2).contains(where: { index.names.contains(normalized($0)) }) { return .ambiguous }
        if parts.count >= 2, index.names.contains(normalized(parts[1])) { return .ambiguous }
        return .orphan
    }

    /// Kinds scanned for leftovers.
    static let scannedKinds: [UninstallFileKind] = [.appSupport, .caches, .preferences, .containers, .groupContainers,
                                                    .savedState, .httpStorage, .webKit, .logs, .cookies, .appScripts]

    /// Candidate orphans in a library folder, before sizes are measured.
    static func candidates(library: URL, index: Index, isKnownApp: (String) -> Bool,
                           fileManager: FileManager = .default) -> [(key: String, item: UninstallLeftoverItem)] {
        var found: [(String, UninstallLeftoverItem)] = []
        for kind in scannedKinds {
            var folders = [library.appendingPathComponent(kind.libraryFolder)]
            if kind == .preferences { folders.append(folders[0].appendingPathComponent("ByHost")) }
            for folder in folders {
                let children = ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []).map { folder.appendingPathComponent($0) }
                for url in children {
                    let name = url.lastPathComponent
                    guard !name.hasPrefix("."), !UninstallSafety.isAppleOwned(name),
                          let id = canonicalID(fromEntryName: name),
                          classify(id, index: index, isKnownApp: isKnownApp) == .orphan,
                          UninstallSafety.isRemovableSupportItem(path: url.path, library: library.path) else { continue }
                    found.append((groupKey(id), UninstallLeftoverItem(url: url, kind: kind,
                                                                       link: UninstallLinks.resolve(url, fileManager: fileManager))))
                }
            }
        }
        return found
    }

    /// Groups measured items, dropping anything modified within the quiet period.
    static func group(_ items: [(key: String, item: UninstallLeftoverItem)], now: Date = .now) -> [UninstallLeftoverGroup] {
        let recent = now.addingTimeInterval(-quietPeriod)
        let fresh = Dictionary(grouping: items, by: \.key)
        var groups: [UninstallLeftoverGroup] = []
        for (key, entries) in fresh {
            let all = entries.map(\.item)
            // If any piece of this app's data changed recently, something still uses it: skip the whole group.
            if all.contains(where: { ($0.newest ?? .distantPast) > recent }) { continue }
            let parts = key.split(separator: ".").map(String.init)
            groups.append(UninstallLeftoverGroup(
                id: key,
                displayName: prettify(parts.count >= 3 ? parts[2] : key),
                vendor: parts.count >= 2 ? parts[1] : "",
                items: all.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }))
        }
        return groups.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.id < $1.id }
    }

    /// "hello-ai" → "Hello AI"-ish: split on separators, capitalise the first letter of each word.
    static func prettify(_ component: String) -> String {
        component.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
