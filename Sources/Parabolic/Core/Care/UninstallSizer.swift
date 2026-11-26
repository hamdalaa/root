import Foundation

/// Allocated size of a file or folder, never following symbolic links.
enum UninstallSizer {
    struct Measurement: Sendable, Equatable {
        /// Bytes on disk. Nil when the item couldn't be read at all.
        var bytes: Int64?
        /// Newest modification date seen anywhere inside.
        var newest: Date?
        /// Some children couldn't be read (permissions), so `bytes` is a lower bound.
        var isPartial: Bool
    }

    private static let keys: [URLResourceKey] = [
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey,
        .contentModificationDateKey,
    ]

    /// Walks the item. Checks for task cancellation every few hundred entries.
    static func measure(_ url: URL) -> Measurement {
        guard let top = try? url.resourceValues(forKeys: Set(keys)) else {
            return Measurement(bytes: nil, newest: nil, isPartial: true)
        }
        var total = Int64(top.totalFileAllocatedSize ?? top.fileAllocatedSize ?? 0)
        var newest = top.contentModificationDate
        guard top.isDirectory == true, top.isSymbolicLink != true else {
            return Measurement(bytes: total, newest: newest, isPartial: false)
        }

        var failed = false
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: []) { _, _ in
            failed = true
            return true
        }
        var visited = 0
        while let child = enumerator?.nextObject() as? URL {
            visited += 1
            if visited % 512 == 0, Task.isCancelled { return Measurement(bytes: nil, newest: newest, isPartial: true) }
            guard let values = try? child.resourceValues(forKeys: Set(keys)) else { failed = true; continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            if let date = values.contentModificationDate, date > (newest ?? .distantPast) { newest = date }
        }
        if enumerator == nil { failed = true }
        return Measurement(bytes: total, newest: newest, isPartial: failed)
    }
}
