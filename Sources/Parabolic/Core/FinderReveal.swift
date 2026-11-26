import AppKit

/// The one "Show in Finder" every screen uses.
///
/// Two things went wrong before: `activateFileViewerSelecting` selected the file but left Finder
/// behind Root (macOS 14+ cooperative activation), and a file that had been moved, deleted or
/// renamed made the button do nothing at all. This resolves what to show, then brings Finder forward.
enum FinderReveal {
    enum Plan: Equatable {
        /// Select these files in a Finder window.
        case select([URL])
        /// None of the files are on disk any more: open the nearest folder that still exists.
        case openFolder(URL)
        /// Nothing usable (no paths, no folder).
        case none
    }

    static let finderBundleID = "com.apple.finder"

    // MARK: Planning (pure, tested)

    /// Decides what Finder should show for `paths`, falling back to `fallbackFolder`.
    static func plan(paths: [String?], fallbackFolder: String? = nil,
                     fileManager fm: FileManager = .default) -> Plan {
        let real = paths.compactMap { $0 }.filter { !$0.isEmpty }
        var found: [URL] = []
        for path in real {
            if let url = locate(path, fileManager: fm), !found.contains(url) { found.append(url) }
        }
        if !found.isEmpty { return .select(found) }
        let folders = real.map { (($0 as NSString).expandingTildeInPath as NSString).deletingLastPathComponent }
            + [fallbackFolder].compactMap { $0 }.filter { !$0.isEmpty }
        for folder in folders {
            if let url = nearestExistingFolder(folder, fileManager: fm) { return .openFolder(url) }
        }
        return .none
    }

    /// The file itself, or where it most likely went: the same name in a direct subfolder
    /// ("Organize by type" sorting), or the same title with another extension (yt-dlp remux/merge).
    static func locate(_ path: String, fileManager fm: FileManager = .default) -> URL? {
        let full = (path as NSString).expandingTildeInPath
        if fm.fileExists(atPath: full) { return URL(fileURLWithPath: full) }
        let dir = (full as NSString).deletingLastPathComponent
        let name = (full as NSString).lastPathComponent
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return nil }

        for entry in entries where isDirectory((dir as NSString).appendingPathComponent(entry), fm) {
            let moved = ((dir as NSString).appendingPathComponent(entry) as NSString).appendingPathComponent(name)
            if fm.fileExists(atPath: moved) { return URL(fileURLWithPath: moved) }
        }

        let wanted = stem(of: name)
        guard !wanted.isEmpty else { return nil }
        let matches = entries.filter { entry in
            !isPartial(entry) && stem(of: entry) == wanted
                && !isDirectory((dir as NSString).appendingPathComponent(entry), fm)
        }
        let newest = matches.max { modified($0, in: dir, fm) < modified($1, in: dir, fm) }
        return newest.map { URL(fileURLWithPath: (dir as NSString).appendingPathComponent($0)) }
    }

    /// `path` or its closest existing parent folder; nil once only "/" is left.
    static func nearestExistingFolder(_ path: String, fileManager fm: FileManager = .default) -> URL? {
        var current = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
        while current != "/" && !current.isEmpty {
            if isDirectory(current, fm) { return URL(fileURLWithPath: current, isDirectory: true) }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// Title part of a file name, Unicode-normalised (Arabic/accents), without the extension and
    /// without a yt-dlp format id such as ".f137".
    static func stem(of name: String) -> String {
        var base = (name as NSString).deletingPathExtension
        if let dot = base.range(of: #"\.f[0-9]+(-[0-9]+)?$"#, options: .regularExpression) {
            base.removeSubrange(dot)
        }
        return base.precomposedStringWithCanonicalMapping
    }

    private static func isPartial(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["part", "ytdl", "aria2", "crdownload", "download", "tmp"].contains(ext) || name.hasPrefix(".")
    }

    private static func isDirectory(_ path: String, _ fm: FileManager) -> Bool {
        var dir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }

    private static func modified(_ name: String, in dir: String, _ fm: FileManager) -> Date {
        let attributes = try? fm.attributesOfItem(atPath: (dir as NSString).appendingPathComponent(name))
        return attributes?[.modificationDate] as? Date ?? .distantPast
    }

    // MARK: Showing

    /// Shows `paths` in Finder (or the nearest folder) and brings Finder to the front.
    /// Returns false when there was nothing to show, so callers can beep.
    @MainActor @discardableResult
    static func reveal(paths: [String?], fallbackFolder: String? = nil) -> Bool {
        show(plan(paths: paths, fallbackFolder: fallbackFolder))
    }

    @MainActor @discardableResult
    static func reveal(_ urls: [URL], fallbackFolder: String? = nil) -> Bool {
        reveal(paths: urls.map(\.path), fallbackFolder: fallbackFolder)
    }

    @MainActor @discardableResult
    static func show(_ plan: Plan) -> Bool {
        switch plan {
        case .select(let urls):
            yieldToFinder()
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        case .openFolder(let folder):
            yieldToFinder()
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
        case .none:
            NSSound.beep()
            return false
        }
        activateFinder()
        // Finder handles the reveal asynchronously and can raise the window it reused a moment later
        // on a different Space; ask once more after it has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { activateFinder() }
        return true
    }

    /// Lets Finder take activation from Root (macOS 14+ cooperative activation refuses it otherwise).
    @MainActor private static func yieldToFinder() {
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: finderBundleID)
    }

    @MainActor private static func activateFinder() {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: finderBundleID).first,
              !finder.isActive else { return }
        if !finder.activate(from: .current, options: []) { finder.activate() }
    }
}
