import Darwin
import Foundation
import Synchronization

/// Measures folders on disk. Uses fts(3) in physical mode: symlinks are never followed, other volumes mounted inside
/// a folder are skipped, and sizes are allocated bytes (st_blocks × 512, the same figure as `totalFileAllocatedSizeKey`).
enum StorageScanner {
    /// Remembers (device, inode) of multiply-linked files so each is counted once per scan.
    final class HardLinks: Sendable {
        private struct Key: Hashable { let device: Int32; let inode: UInt64 }
        private let seen = Mutex<Set<Key>>([])

        init() {}

        /// True the first time a given file is seen.
        func firstSighting(device: Int32, inode: UInt64) -> Bool {
            seen.withLock { $0.insert(Key(device: device, inode: inode)).inserted }
        }
    }

    /// The outcome of measuring one folder tree.
    struct Walk: Sendable {
        var bytes: Int64 = 0
        var files = 0
        var unreadable = 0
        var unreadableSamples: [String] = []
        var skippedVolumes = 0
        /// Contents of the walked folder and of folders up to `recordDepth` levels below it.
        var listings: [URL: StorageListing] = [:]
        var cancelled = false
    }

    static let sampleLimit = 12

    // MARK: Streaming scan of one folder

    /// Lists `folder`, sizes its files immediately and measures its subfolders concurrently, streaming results.
    /// Cancelling the consuming task (or dropping the stream) stops the walk.
    /// `known` maps folder paths to an already measured item; those folders are reported without walking them again.
    static func scan(_ folder: URL, known: [String: StorageItem] = [:],
                     concurrency: Int = defaultConcurrency) -> AsyncStream<StorageScanEvent> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                await run(folder, known: known, concurrency: max(1, concurrency), continuation)
                continuation.yield(.finished(cancelled: Task.isCancelled))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static var defaultConcurrency: Int { max(2, min(6, ProcessInfo.processInfo.activeProcessorCount / 2)) }

    private static func run(_ folder: URL, known: [String: StorageItem], concurrency: Int,
                            _ continuation: AsyncStream<StorageScanEvent>.Continuation) async {
        var rootStat = stat()
        guard lstat(folder.path, &rootStat) == 0 else {
            continuation.yield(.failed(String(cString: strerror(errno)), permissionDenied: errno == EPERM || errno == EACCES))
            return
        }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch {
            let denied = (error as? CocoaError)?.code == .fileReadNoPermission
                || ((error as NSError).underlyingErrors.first as NSError?).map { $0.code == Int(EPERM) || $0.code == Int(EACCES) } == true
            continuation.yield(.failed(error.localizedDescription, permissionDenied: denied))
            return
        }

        let hardLinks = HardLinks()
        let allowedDevices = allowedDevices(for: folder, rootDevice: rootStat.st_dev)
        var items: [StorageItem] = []
        var pending: [URL] = []
        var skippedVolumes = 0

        for name in names {
            let url = folder.appendingPathComponent(name)
            var st = stat()
            guard lstat(url.path, &st) == 0 else { continue }
            switch st.st_mode & S_IFMT {
            case S_IFLNK:
                items.append(StorageItem(url: url, kind: .symlink, bytes: allocated(st)))
            case S_IFDIR:
                guard allowedDevices.contains(st.st_dev) else { skippedVolumes += 1; continue }
                let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
                let item = StorageItem(url: url, kind: isPackage ? .package : .folder, bytes: 0, isSizing: true)
                items.append(item)
                pending.append(url)
            default:
                let counted = st.st_nlink <= 1 || hardLinks.firstSighting(device: st.st_dev, inode: st.st_ino)
                items.append(StorageItem(url: url, kind: .file, bytes: counted ? allocated(st) : 0, fileCount: 1))
            }
        }

        continuation.yield(.listed(.make(folder: folder, items: items, skippedVolumes: skippedVolumes,
                                         selfBytes: allocated(rootStat), keep: .max, isComplete: pending.isEmpty)))
        pending.removeAll { url in
            guard var item = known[url.path] else { return false }
            item = StorageItem(url: url, kind: item.kind, bytes: item.bytes, fileCount: item.fileCount,
                               unreadable: item.unreadable)
            continuation.yield(.sized(item, listings: [:], unreadableSamples: []))
            return true
        }
        guard !pending.isEmpty else { return }

        let kinds = Dictionary(uniqueKeysWithValues: items.map { ($0.url, $0.kind) })
        await withTaskGroup(of: Void.self) { group in
            var queue = pending[...]
            func next() {
                guard let url = queue.popFirst() else { return }
                let kind = kinds[url] ?? .folder
                group.addTask {
                    guard !Task.isCancelled else { return }
                    let measured = walk(url, hardLinks: hardLinks, recordDepth: kind == .package ? -1 : 1) { bytes, files in
                        continuation.yield(.progress(url, bytes: bytes, files: files))
                    }
                    let item = StorageItem(url: url, kind: kind, bytes: measured.bytes, fileCount: measured.files,
                                           unreadable: measured.unreadable, isSizing: measured.cancelled)
                    continuation.yield(.sized(item, listings: measured.listings, unreadableSamples: measured.unreadableSamples))
                }
            }
            for _ in 0..<concurrency { next() }
            for await _ in group {
                if Task.isCancelled { group.cancelAll(); break }
                next()
            }
        }
    }

    /// Devices a scan of `folder` may descend into. At "/" the firmlinked Data volume counts as the same disk.
    private static func allowedDevices(for folder: URL, rootDevice: dev_t) -> Set<dev_t> {
        var devices: Set<dev_t> = [rootDevice]
        if folder.path == "/" {
            var data = stat()
            if lstat("/System/Volumes/Data", &data) == 0 { devices.insert(data.st_dev) }
        }
        return devices
    }

    @inline(__always) static func allocated(_ st: stat) -> Int64 { Int64(st.st_blocks) * 512 }

    // MARK: Tree walk

    private struct Frame {
        let url: URL?
        let level: Int
        let kind: StorageItem.Kind
        let otherVolume: Bool
        var bytes: Int64 = 0
        var files = 0
        var unreadable = 0
        var skippedVolumes = 0
        var selfBytes: Int64 = 0
        var entries: [StorageItem]?
    }

    /// Measures everything under `root` (synchronously). Records listings for `root` and folders up to `recordDepth`
    /// levels below it (pass -1 to record none). `progress` is called a few times a second with the running total.
    static func walk(_ root: URL, hardLinks: HardLinks = HardLinks(), recordDepth: Int = 1,
                     progress: ((Int64, Int) -> Void)? = nil) -> Walk {
        var result = Walk()
        guard let cPath = strdup(root.path) else { return result }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else {
            result.unreadable = 1
            result.unreadableSamples = [root.path]
            return result
        }
        defer { fts_close(fts) }

        var stack: [Frame] = []
        var rootDevice: dev_t?
        var visited = 0
        var lastReport = DispatchTime.now().uptimeNanoseconds

        func url(of entry: UnsafeMutablePointer<FTSENT>, isDirectory: Bool) -> URL {
            URL(fileURLWithFileSystemRepresentation: entry.pointee.fts_path, isDirectory: isDirectory, relativeTo: nil)
        }

        func noteUnreadable(_ entry: UnsafeMutablePointer<FTSENT>) {
            result.unreadable += 1
            if result.unreadableSamples.count < sampleLimit {
                result.unreadableSamples.append(String(cString: entry.pointee.fts_path))
            }
        }

        func pop(unreadable: Bool) {
            guard var frame = stack.popLast() else { return }
            if unreadable { frame.unreadable += 1 }
            if let entries = frame.entries, let url = frame.url {
                result.listings[url] = .make(folder: url, items: entries, unreadable: frame.unreadable,
                                             skippedVolumes: frame.skippedVolumes, selfBytes: frame.selfBytes,
                                             isComplete: !result.cancelled)
            }
            guard !stack.isEmpty else {
                result.bytes = frame.bytes
                result.files = frame.files
                result.skippedVolumes = frame.skippedVolumes
                return
            }
            if frame.otherVolume {
                stack[stack.count - 1].skippedVolumes += 1
                return
            }
            stack[stack.count - 1].bytes += frame.bytes
            stack[stack.count - 1].files += frame.files
            stack[stack.count - 1].unreadable += frame.unreadable
            if stack[stack.count - 1].entries != nil, let url = frame.url {
                stack[stack.count - 1].entries?.append(StorageItem(url: url, kind: frame.kind, bytes: frame.bytes,
                                                                   fileCount: frame.files, unreadable: frame.unreadable,
                                                                   isSizing: result.cancelled))
            }
        }

        while let entry = fts_read(fts) {
            visited += 1
            if visited & 511 == 0 {
                if Task.isCancelled { result.cancelled = true; break }
                if let progress {
                    let now = DispatchTime.now().uptimeNanoseconds
                    if now - lastReport > 150_000_000 {
                        lastReport = now
                        progress(stack.reduce(0) { $0 + $1.bytes }, stack.reduce(0) { $0 + $1.files })
                    }
                }
            }
            let level = Int(entry.pointee.fts_level)
            let info = Int32(entry.pointee.fts_info)
            switch info {
            case FTS_D:
                let st = entry.pointee.fts_statp.pointee
                if rootDevice == nil { rootDevice = st.st_dev }
                let otherVolume = st.st_dev != rootDevice
                let needsURL = level <= recordDepth + 1
                let dirURL = needsURL ? url(of: entry, isDirectory: true) : nil
                var kind = StorageItem.Kind.folder
                if level > 0, let dirURL, (try? dirURL.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true {
                    kind = .package
                }
                let records = level <= recordDepth && kind == .folder && !otherVolume
                let own = otherVolume ? 0 : allocated(st)
                stack.append(Frame(url: dirURL, level: level, kind: kind, otherVolume: otherVolume,
                                   bytes: own, selfBytes: own, entries: records ? [] : nil))
            case FTS_DP:
                pop(unreadable: false)
            case FTS_DNR, FTS_ERR:
                noteUnreadable(entry)
                if let top = stack.last, top.level == level { pop(unreadable: true) }
            case FTS_NS:
                noteUnreadable(entry)
                if !stack.isEmpty { stack[stack.count - 1].unreadable += 1 }
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                let st = entry.pointee.fts_statp.pointee
                guard !stack.isEmpty else {
                    // The root itself is a file or a symlink.
                    result.bytes = allocated(st)
                    result.files = 1
                    continue
                }
                let counted = info != FTS_F || st.st_nlink <= 1 || hardLinks.firstSighting(device: st.st_dev, inode: st.st_ino)
                let bytes = counted ? allocated(st) : 0
                stack[stack.count - 1].bytes += bytes
                stack[stack.count - 1].files += info == FTS_F ? 1 : 0
                if stack[stack.count - 1].entries != nil {
                    let kind: StorageItem.Kind = info == FTS_SL || info == FTS_SLNONE ? .symlink : .file
                    stack[stack.count - 1].entries?.append(StorageItem(url: url(of: entry, isDirectory: false), kind: kind,
                                                                       bytes: bytes, fileCount: info == FTS_F ? 1 : 0))
                }
            default:
                break
            }
        }
        // Stopped early: fold what was measured so far into the partial totals.
        while !stack.isEmpty { pop(unreadable: false) }
        return result
    }
}
