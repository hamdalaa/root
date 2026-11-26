import Foundation
@testable import Parabolic

/// A throwaway home folder under the temp directory. Everything Cleanup tests touch lives inside it.
final class CleanupTempHome {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanup-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func file(_ path: String, bytes: Int = 10_000, age days: Double? = nil) -> URL {
        let target = url.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: target.path, contents: Data(repeating: 0x61, count: bytes))
        if let days { age(path, days: days) }
        return target
    }

    @discardableResult
    func folder(_ path: String, age days: Double? = nil) -> URL {
        let target = url.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        if let days { age(path, days: days) }
        return target
    }

    func link(_ path: String, to destination: URL) {
        let target = url.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(at: target, withDestinationURL: destination)
    }

    /// Sets the modification date of `path` to `days` ago.
    func age(_ path: String, days: Double) {
        let date = Date().addingTimeInterval(-days * 86_400)
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.appendingPathComponent(path).path)
    }

    /// Ages a whole tree, deepest first, so folder dates aren't refreshed by their children.
    func ageTree(_ path: String, days: Double) {
        let root = url.appendingPathComponent(path)
        let paths = (FileManager.default.subpaths(atPath: root.path) ?? []).sorted { $0.count > $1.count }
        for sub in paths { age(path + "/" + sub, days: days) }
        age(path, days: days)
    }

    func environment(runningApps: [CleanupRunningApp] = [], projectIdleDays: Int = 30,
                     mounted: Set<String> = [], volumeTrashes: [URL] = [],
                     lastTouched: (@Sendable (URL) -> Date?)? = nil) -> CleanupEnvironment {
        CleanupEnvironment(home: url, runningApps: runningApps,
                           projectRoots: CleanupLocations.defaultProjectRoots(home: url),
                           projectIdleDays: projectIdleDays, mountedImagePaths: mounted,
                           volumeTrashRoots: volumeTrashes,
                           lastTouched: lastTouched ?? { CleanupFS.modificationDate($0) })
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(path).path)
    }
}

extension CleanupCategoryResult {
    var names: [String] { items.map(\.name) }
    var paths: [String] { items.map { $0.url.path } }

    func item(endingWith suffix: String) -> CleanupItem? {
        items.first { $0.url.path.hasSuffix(suffix) }
    }
}
