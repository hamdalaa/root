import Foundation

/// One Spotlight hit, copied out of NSMetadataItem so it can leave the main actor.
struct StorageSpotlightHit: Sendable {
    let path: String
    let size: Int64?
    let lastUsed: Date?
    let contentTypes: [String]
}

/// Runs a single `kMDItemFSSize >= N` Spotlight query over a set of folders and returns the hits once gathering ends.
@MainActor
final class StorageSpotlightQuery {
    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?
    private var continuation: CheckedContinuation<[StorageSpotlightHit], Never>?

    init() {}

    /// Returns every hit. Cancelling the calling task stops the query and returns what was gathered (usually nothing).
    func run(scopes: [URL], minimum: Int64) async -> [StorageSpotlightHit] {
        stop()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                let query = NSMetadataQuery()
                query.predicate = NSPredicate(format: "%K >= %lld", NSMetadataItemFSSizeKey, minimum)
                query.searchScopes = scopes
                query.notificationBatchingInterval = 0.25
                self.query = query
                observer = NotificationCenter.default.addObserver(
                    forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.finish() }
                }
                if !query.start() { finish() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish() }
        }
    }

    private func finish() {
        guard let continuation else { return }
        self.continuation = nil
        var hits: [StorageSpotlightHit] = []
        if let query {
            query.disableUpdates()
            hits.reserveCapacity(query.resultCount)
            for index in 0..<query.resultCount {
                guard let item = query.result(at: index) as? NSMetadataItem,
                      let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
                hits.append(StorageSpotlightHit(
                    path: path,
                    size: (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value,
                    lastUsed: item.value(forAttribute: "kMDItemLastUsedDate") as? Date,
                    contentTypes: item.value(forAttribute: NSMetadataItemContentTypeTreeKey) as? [String] ?? []
                ))
            }
        }
        stop()
        continuation.resume(returning: hits)
    }

    func stop() {
        query?.stop()
        query = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: [])
        }
    }
}
