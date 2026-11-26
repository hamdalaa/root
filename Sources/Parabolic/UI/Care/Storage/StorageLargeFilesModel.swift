import Foundation
import Observation

/// Large Files: Spotlight first, a direct walk for disks Spotlight doesn't index. Shared so results survive screen switches.
@MainActor
@Observable
final class StorageLargeFilesModel {
    static let shared = StorageLargeFilesModel()

    enum Phase: Equatable {
        case idle
        case searching(String)
        case done
        case stopped
    }

    /// How one search scope was searched, shown under the results.
    struct ScopeNote: Equatable, Identifiable {
        enum Method: Equatable { case spotlight, walk }
        let name: String
        let method: Method
        var unreadable = 0
        var id: String { name }
    }

    private(set) var phase: Phase = .idle
    /// Everything found at `queriedMinimum`; lower thresholds need a new search, higher ones just filter.
    private(set) var all: [StorageLargeFile] = []
    private(set) var queriedMinimum: Int64?
    private(set) var notes: [ScopeNote] = []
    private(set) var threshold: StorageThreshold = .gb1
    private(set) var kind: StorageFileKind?
    private(set) var selection: Set<URL> = []
    private(set) var sortOrder: [KeyPathComparator<StorageLargeFile>] = [KeyPathComparator(\.diskBytes, order: .reverse)]
    private(set) var searchedAt: Date?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var resumeOnAppear = false
    @ObservationIgnored private let spotlight = StorageSpotlightQuery()

    // MARK: Derived

    /// At or above the threshold, ignoring the kind filter.
    var aboveThreshold: [StorageLargeFile] { StorageLargeFileSearch.filter(all, minimum: threshold.rawValue) }

    var visible: [StorageLargeFile] {
        StorageLargeFileSearch.filter(all, minimum: threshold.rawValue, kind: kind).sorted(using: sortOrder)
    }

    var kindCounts: [(kind: StorageFileKind, count: Int, bytes: Int64)] {
        let files = aboveThreshold
        return StorageFileKind.allCases.compactMap { kind in
            let matching = files.filter { $0.kind == kind }
            return matching.isEmpty ? nil : (kind, matching.count, matching.reduce(0) { $0 + $1.diskBytes })
        }
    }

    var selectedFiles: [StorageLargeFile] { all.filter { selection.contains($0.url) } }

    var isSearching: Bool { if case .searching = phase { true } else { false } }

    // MARK: Inputs (equality-guarded)

    func setThreshold(_ value: StorageThreshold) {
        guard value != threshold else { return }
        threshold = value
        pruneSelection()
        if let queriedMinimum, value.rawValue >= queriedMinimum, phase == .done { return }
        search()
    }

    func setKind(_ value: StorageFileKind?) {
        guard value != kind else { return }
        kind = value
        pruneSelection()
    }

    func setSelection(_ value: Set<URL>) { if value != selection { selection = value } }

    func setSortOrder(_ value: [KeyPathComparator<StorageLargeFile>]) { if value != sortOrder { sortOrder = value } }

    private func pruneSelection() {
        let visibleIDs = Set(visible.map(\.url))
        let pruned = selection.intersection(visibleIDs)
        if pruned != selection { selection = pruned }
    }

    // MARK: Lifecycle

    func appeared() {
        if phase == .idle || resumeOnAppear {
            resumeOnAppear = false
            search()
        }
    }

    func disappeared() {
        guard isSearching else { return }
        resumeOnAppear = true
        stop()
    }

    func stop() {
        task?.cancel()
        task = nil
        spotlight.stop()
        if isSearching { phase = all.isEmpty && queriedMinimum == nil ? .idle : .stopped }
    }

    // MARK: Search

    func search() {
        task?.cancel()
        let minimum = threshold.rawValue
        task = Task { [weak self] in await self?.run(minimum: minimum) }
    }

    private func run(minimum: Int64) async {
        phase = .searching("Checking which disks Spotlight indexes…")
        await StorageVolumesStore.shared.refresh()
        let volumes = StorageVolumesStore.shared.volumes
        let home = FileManager.default.homeDirectoryForCurrentUser
        var spotlightScopes: [URL] = []
        var walkScopes: [URL] = []
        for scope in StorageLargeFileSearch.scopes(volumes: volumes, home: home) {
            // The home folder lives on the startup disk; mdutil answers per volume.
            let probe = scope == home ? URL(fileURLWithPath: "/") : scope
            if await StorageLargeFileSearch.isIndexed(probe) == false { walkScopes.append(scope) } else { spotlightScopes.append(scope) }
        }
        guard !Task.isCancelled else { return }

        func name(_ url: URL) -> String {
            url == home ? "Home" : (volumes.first { $0.url == url }?.name ?? url.lastPathComponent)
        }

        var found: [StorageLargeFile] = []
        var newNotes: [ScopeNote] = spotlightScopes.map { ScopeNote(name: name($0), method: .spotlight) }

        if !spotlightScopes.isEmpty {
            phase = .searching("Asking Spotlight for files over \(Format.bytes(minimum))…")
            let hits = await spotlight.run(scopes: spotlightScopes, minimum: minimum)
            guard !Task.isCancelled else { return }
            phase = .searching("Measuring \(hits.count.formatted()) result\(hits.count == 1 ? "" : "s")…")
            found += await Self.measure(hits)
        }
        for scope in walkScopes {
            guard !Task.isCancelled else { return }
            let label = name(scope)
            phase = .searching("Spotlight is off on \(label), so Root is walking it directly…")
            let result = await Self.walk(scope, minimum: minimum) { [weak self] checked in
                Task { @MainActor in
                    guard let self, self.isSearching else { return }
                    self.phase = .searching("Walking \(label) without Spotlight · \(checked.formatted()) items checked")
                }
            }
            found += result.files
            newNotes.append(ScopeNote(name: label, method: .walk, unreadable: result.unreadable))
        }
        guard !Task.isCancelled else { return }

        var seen = Set<String>()
        all = found.filter { seen.insert($0.url.path).inserted }
        queriedMinimum = minimum
        notes = newNotes
        searchedAt = Date()
        phase = .done
        pruneSelection()
    }

    /// Stats each Spotlight hit (and measures bundles) off the main actor.
    nonisolated private static func measure(_ hits: [StorageSpotlightHit]) async -> [StorageLargeFile] {
        await withTaskGroup(of: StorageLargeFile?.self) { group in
            var results: [StorageLargeFile] = []
            var iterator = hits.makeIterator()
            func add() {
                guard let hit = iterator.next() else { return }
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    return StorageLargeFileSearch.makeFile(path: hit.path, size: hit.size, lastUsed: hit.lastUsed,
                                                           contentTypes: hit.contentTypes)
                }
            }
            for _ in 0..<4 { add() }
            for await file in group {
                if let file { results.append(file) }
                add()
            }
            return results
        }
    }

    nonisolated private static func walk(_ root: URL, minimum: Int64,
                                         progress: @escaping @Sendable (Int) -> Void) async -> (files: [StorageLargeFile], unreadable: Int) {
        StorageLargeFileSearch.walk(root, minimum: minimum, progress: progress)
    }

    // MARK: Trash

    func trash(_ urls: [URL]) async -> [(URL, String)] {
        let sizes = Dictionary(uniqueKeysWithValues: all.map { ($0.url, $0.diskBytes) })
        let failures = await StorageSafety.trash(urls)
        let failed = Set(failures.map(\.0))
        let moved = urls.filter { !failed.contains($0) }
        all.removeAll { moved.contains($0.url) }
        selection.subtract(moved)
        for url in moved { StorageExplorerModel.shared.forget(url, bytes: sizes[url]) }
        await StorageVolumesStore.shared.refresh()
        return failures
    }
}
