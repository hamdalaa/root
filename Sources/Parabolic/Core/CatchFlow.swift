import Foundation

/// What happens to a caught download (browser extension, magnet link, .torrent file):
/// the FDM-style popup, or straight into the queue.
enum CatchFlow {
    enum Route: Equatable, Sendable { case popup, enqueue }

    /// Lowercased extension ("zip"), from the file name the browser gave, else the link. "" when there is none.
    static func fileType(of item: BrowserItem) -> String {
        if item.url.lowercased().hasPrefix("magnet:") { return "torrent" }
        let name = item.filename.flatMap { $0.isEmpty ? nil : $0 } ?? URL(string: item.url)?.lastPathComponent ?? ""
        return fileType(ofFilename: name)
    }

    static func fileType(ofFilename name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        guard (1...8).contains(ext.count), ext.allSatisfy({ $0.isLetter || $0.isNumber }) else { return "" }
        return ext
    }

    /// A page yt-dlp downloads from (YouTube, Instagram…), not a file: the popup offers quality choices.
    static func isMediaPage(_ url: String) -> Bool {
        EngineRouter.engine(for: url) == .media
    }

    /// The popup, unless it's turned off in Settings or «Don't ask for … files» was ticked for this type.
    static func route(_ item: BrowserItem, prefs: Preferences) -> Route {
        guard prefs.browserShowCatchWindow else { return .enqueue }
        let type = fileType(of: item)
        return !type.isEmpty && prefs.catchSkipTypes.contains(type) ? .enqueue : .popup
    }

    /// The folder the popup starts in: the last one picked there while it still exists, else the download folder.
    static func startFolder(prefs: Preferences, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
        let last = prefs.catchLastFolder
        return !last.isEmpty && exists(last) ? last : prefs.downloadFolder
    }

    /// After «Download» or «Download Later»: keeps the folder for next time, and the "don't ask" choice.
    static func remember(folder: String, skipType: String?, in prefs: inout Preferences) {
        if prefs.catchLastFolder != folder { prefs.catchLastFolder = folder }
        if let skipType, !skipType.isEmpty, !prefs.catchSkipTypes.contains(skipType) {
            prefs.catchSkipTypes.append(skipType)
        }
    }
}

/// What «Download» / «Download Later» hands to the download manager.
struct CatchRequest: Equatable, Sendable {
    let url: String
    let filename: String
    let headers: [String: String]?
    let folder: String
    let size: Int64?
    let startPaused: Bool
    /// Quality/format for media pages; nil for files.
    var preset: DownloadPreset? = nil
}

/// The facts in the popup's «More details», computed honestly: nil / unknown rather than a guess.
enum CatchDetails {
    enum Space: Equatable, Sendable { case plenty, low, notEnough, unknown }

    /// Less than this left after the download counts as low.
    static let lowSpaceMargin: Int64 = 2_000_000_000

    /// Seconds to download `bytes` at `mbps` (Root's last speed test). Nil without both.
    static func eta(bytes: Int64?, mbps: Double?) -> Int? {
        guard let bytes, bytes > 0, let mbps, mbps > 0 else { return nil }
        let seconds = Double(bytes) * 8 / (mbps * 1_000_000)
        return max(1, Int(seconds.rounded(.up)))
    }

    /// "about 12 sec", "about 3 min, 5 sec".
    static func etaText(_ seconds: Int) -> String {
        "about " + Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated,
                                                              maximumUnitCount: 2))
    }

    static func space(free: Int64?, needed: Int64?) -> Space {
        guard let free else { return .unknown }
        if let needed, free < needed { return .notEnough }
        return free - (needed ?? 0) < lowSpaceMargin ? .low : .plenty
    }

    /// Free space on the volume of `folder` (or its nearest existing parent, for a folder not made yet).
    static func freeSpace(at folder: String) -> Int64? {
        var url = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
            url.deleteLastPathComponent()
        }
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        return values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init)
    }

    /// aria2 connections for this file: one when the server can't do ranges, 16 in Turbo.
    static func connections(prefs: Preferences, resumable: Bool?) -> Int {
        if resumable == false { return 1 }
        return prefs.turboMode ? 16 : max(1, min(16, prefs.directConnections))
    }
}
