import CryptoKit
import Foundation
import os

/// Keeps a copy of the browser extension outside the app bundle.
///
/// Chromium loads an unpacked extension from a folder path. When that folder was inside Root.app, every rebuild
/// or reinstall deleted it and Brave silently dropped the extension (the 2026-10-21 → 11-18 outage). The copy in
/// Application Support survives app updates; Root refreshes its files in place on launch, so the browser picks
/// up a new version the next time it reloads the extension, without the folder ever disappearing.
enum ExtensionInstaller {
    static var stableFolder: URL { ToolStore.supportDirectory.appendingPathComponent("Extension", isDirectory: true) }
    static var chromiumFolder: URL { stableFolder.appendingPathComponent("chromium", isDirectory: true) }
    static var firefoxPackage: URL { stableFolder.appendingPathComponent("parabolic-firefox.xpi") }

    private static let log = Logger(subsystem: "com.hamad.parabolic", category: "extension")

    /// `installFromBundle` for callers with nowhere to show an error: a failure goes to the system log.
    static func installFromBundleOrLog() {
        do {
            try installFromBundle()
        } catch {
            log.error("Couldn’t update the extension copy at \(chromiumFolder.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Mirrors the extension shipped in the bundle into `stableFolder`. Returns files written or removed.
    @discardableResult
    static func installFromBundle() throws -> Int {
        guard let bundled = BrowserBridge.extensionFolder else { return 0 }
        var changed = try sync(from: bundled.appendingPathComponent("chromium", isDirectory: true), to: chromiumFolder)
        let xpi = bundled.appendingPathComponent("parabolic-firefox.xpi")
        if let data = FileManager.default.contents(atPath: xpi.path),
           FileManager.default.contents(atPath: firefoxPackage.path) != data {
            try data.write(to: firefoxPackage, options: .atomic)
            changed += 1
        }
        return changed
    }

    /// Mirrors `source` into `destination` in place: new and changed files are written atomically, files that
    /// are gone from `source` are removed, and `destination` itself is never deleted or replaced.
    @discardableResult
    static func sync(from source: URL, to destination: URL) throws -> Int {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path])
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let wanted = try relativeFiles(in: source)
        var changed = 0
        for path in wanted {
            let from = source.appendingPathComponent(path), to = destination.appendingPathComponent(path)
            let data = try Data(contentsOf: from)
            if let existing = fm.contents(atPath: to.path), digest(existing) == digest(data) { continue }
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: to, options: .atomic)
            changed += 1
        }
        for path in try relativeFiles(in: destination) where !wanted.contains(path) {
            try fm.removeItem(at: destination.appendingPathComponent(path))
            changed += 1
        }
        return changed
    }

    /// Regular files under `folder`, as paths relative to it ("icons/icon-16.png").
    private static func relativeFiles(in folder: URL) throws -> Set<String> {
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var files: Set<String> = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard full.hasPrefix(base + "/") else { continue }
            files.insert(String(full.dropFirst(base.count + 1)))
        }
        return files
    }

    private static func digest(_ data: Data) -> SHA256.Digest { SHA256.hash(data: data) }
}
