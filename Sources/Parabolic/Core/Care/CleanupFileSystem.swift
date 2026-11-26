import Darwin
import Foundation
import os

/// Thread-safe cancel flag shared by the scanners running on background queues.
final class CleanupCancellation: Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)

    init() {}

    var isCancelled: Bool { flag.withLock { $0 } }
    func cancel() { flag.withLock { $0 = true } }
}

/// Measured size of a file or folder.
struct CleanupMeasurement: Sendable, Equatable {
    var bytes: Int64
    /// Sub-folders or files that couldn't be read.
    var denied: Int
}

/// Low-level, symlink-safe file system reads used by every scanner.
enum CleanupFS {
    /// Junk-free directory listing. Throws when the folder exists but can't be read.
    static func children(of directory: URL) throws -> [URL] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return names
            .filter { $0 != ".DS_Store" && $0 != ".localized" }
            .map { directory.appendingPathComponent($0) }
    }

    /// Lists a folder, recording a denial instead of throwing. Missing folders return [].
    static func children(of directory: URL, denied: inout Int) -> [URL] {
        guard exists(directory) else { return [] }
        do { return try children(of: directory) } catch {
            denied += 1
            return []
        }
    }

    static func lstatInfo(_ url: URL) -> stat? {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info : nil
    }

    static func exists(_ url: URL) -> Bool { lstatInfo(url) != nil }

    static func isSymlink(_ url: URL) -> Bool {
        guard let info = lstatInfo(url) else { return false }
        return (info.st_mode & S_IFMT) == S_IFLNK
    }

    /// A real directory (not a link to one).
    static func isDirectory(_ url: URL) -> Bool {
        guard let info = lstatInfo(url) else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    static func isRegularFile(_ url: URL) -> Bool {
        guard let info = lstatInfo(url) else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG
    }

    static func modificationDate(_ url: URL) -> Date? {
        guard let info = lstatInfo(url) else { return nil }
        let spec = info.st_mtimespec
        return Date(timeIntervalSince1970: TimeInterval(spec.tv_sec) + TimeInterval(spec.tv_nsec) / 1_000_000_000)
    }

    /// Allocated bytes on disk, walking physically (never following links) and staying on one volume.
    /// Hard-linked files are counted once.
    static func measure(_ url: URL, cancel: CleanupCancellation? = nil) -> CleanupMeasurement {
        guard let path = strdup(url.path) else { return CleanupMeasurement(bytes: 0, denied: 0) }
        defer { free(path) }
        var argv: [UnsafeMutablePointer<CChar>?] = [path, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            return CleanupMeasurement(bytes: 0, denied: 1)
        }
        defer { fts_close(fts) }

        var bytes: Int64 = 0
        var denied = 0
        var seenLinks = Set<HardLinkKey>()
        var visited = 0
        while let entry = fts_read(fts) {
            visited += 1
            if visited & 0x7FF == 0, cancel?.isCancelled == true { break }
            switch Int32(entry.pointee.fts_info) {
            case FTS_DNR, FTS_ERR, FTS_NS:
                denied += 1
            case FTS_DP, FTS_DC:
                continue
            default:
                guard let statp = entry.pointee.fts_statp else { continue }
                let info = statp.pointee
                if (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink > 1 {
                    let key = HardLinkKey(device: info.st_dev, inode: info.st_ino)
                    guard seenLinks.insert(key).inserted else { continue }
                }
                bytes += Int64(info.st_blocks) * 512
            }
        }
        return CleanupMeasurement(bytes: bytes, denied: denied)
    }

    private struct HardLinkKey: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    // MARK: Zip payload sniffing

    /// True when one of the first `maxEntries` names in a zip's central directory is an app, package or disk image.
    /// Reads only the end of the file; never extracts anything.
    static func zipContainsInstaller(_ url: URL, maxEntries: Int = 64) -> Bool {
        guard let names = zipEntryNames(url, limit: maxEntries) else { return false }
        return names.contains(where: isInstallerPayloadName)
    }

    static func isInstallerPayloadName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if lowered.hasPrefix("__macosx/") { return false }
        return [".app/", ".pkg", ".mpkg", ".dmg", ".xip"].contains { lowered.contains($0) }
    }

    /// Entry names from the central directory, or nil if this isn't a readable (non-zip64) zip.
    static func zipEntryNames(_ url: URL, limit: Int) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size >= 22 else { return nil }
        let tailLength = min(size, 65_557)
        guard (try? handle.seek(toOffset: size - tailLength)) != nil,
              let tail = try? handle.read(upToCount: Int(tailLength)), tail.count >= 22 else { return nil }
        let bytes = [UInt8](tail)

        var eocd: Int?
        var index = bytes.count - 22
        while index >= 0 {
            if bytes[index] == 0x50, bytes[index + 1] == 0x4B, bytes[index + 2] == 0x05, bytes[index + 3] == 0x06 {
                eocd = index
                break
            }
            index -= 1
        }
        guard let eocd else { return nil }
        let count = Int(le16(bytes, eocd + 10))
        let directorySize = UInt64(le32(bytes, eocd + 12))
        let directoryOffset = UInt64(le32(bytes, eocd + 16))
        guard directoryOffset != 0xFFFF_FFFF, directoryOffset + directorySize <= size,
              (try? handle.seek(toOffset: directoryOffset)) != nil,
              let directory = try? handle.read(upToCount: Int(min(directorySize, 4_000_000))) else { return nil }
        let entries = [UInt8](directory)

        var names: [String] = []
        var cursor = 0
        while names.count < min(count, limit), cursor + 46 <= entries.count {
            guard le32(entries, cursor) == 0x0201_4B50 else { break }
            let nameLength = Int(le16(entries, cursor + 28))
            let extraLength = Int(le16(entries, cursor + 30))
            let commentLength = Int(le16(entries, cursor + 32))
            let start = cursor + 46
            guard start + nameLength <= entries.count else { break }
            names.append(String(decoding: entries[start..<start + nameLength], as: UTF8.self))
            cursor = start + nameLength + extraLength + commentLength
        }
        return names
    }

    private static func le16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }

    private static func le32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }
}
