import AppKit
import Foundation

/// Reads every mounted, browsable volume and its capacity from the system.
enum StorageVolumeReader {
    private static let keys: [URLResourceKey] = [
        .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey, .volumeIsRemovableKey,
        .volumeIsEjectableKey, .volumeIsRootFileSystemKey, .volumeIsLocalKey, .volumeIsBrowsableKey,
        .volumeLocalizedFormatDescriptionKey,
    ]

    /// Blocking: an asleep external disk can take a moment to answer. Call off the main actor.
    static func read() -> [StorageVolume] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        let volumes = urls.compactMap(volume(at:))
        return sort(volumes)
    }

    static func volume(at url: URL) -> StorageVolume? {
        var url = url
        url.removeAllCachedResourceValues()
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        let path = url.path
        if path.hasPrefix("/System/Volumes/") || values.volumeIsBrowsable == false { return nil }
        guard let total = values.volumeTotalCapacity, total > 0 else { return nil }
        let isRoot = values.volumeIsRootFileSystem == true || path == "/"
        return StorageVolume(
            url: url,
            name: values.volumeLocalizedName ?? url.lastPathComponent,
            total: Int64(total),
            free: Int64(values.volumeAvailableCapacity ?? 0),
            availableForImportant: values.volumeAvailableCapacityForImportantUsage.flatMap { $0 > 0 ? $0 : nil },
            isInternal: values.volumeIsInternal == true,
            isRemovable: values.volumeIsRemovable == true || values.volumeIsEjectable == true,
            isRoot: isRoot,
            isLocal: values.volumeIsLocal != false,
            format: values.volumeLocalizedFormatDescription
        )
    }

    /// Startup disk first, then other internal volumes, then external ones by name.
    static func sort(_ volumes: [StorageVolume]) -> [StorageVolume] {
        volumes.sorted { a, b in
            if a.isRoot != b.isRoot { return a.isRoot }
            if a.isInternal != b.isInternal { return a.isInternal }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    @MainActor static func icon(for volume: StorageVolume) -> NSImage {
        NSWorkspace.shared.icon(forFile: volume.url.path)
    }
}
