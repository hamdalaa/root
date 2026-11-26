import Foundation
import Observation

/// Results and selection for the Search screen. One shared instance so results survive navigating away.
@MainActor
@Observable
final class SearchModel {
    static let shared = SearchModel()

    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
        case toolMissing
    }

    private(set) var phase: Phase = .idle
    private(set) var results: [PlaylistEntry] = []
    /// The query and source the current results (or error) belong to.
    private(set) var resultQuery = ""
    private(set) var resultSource: SearchSource = .youtube

    var isSelecting = false
    var selection: Set<String> = []
    /// Links queued from this screen, so cards can show a checkmark.
    private(set) var queuedURLs: Set<String> = []

    @ObservationIgnored private var task: Task<Void, Never>?

    static let resultLimit = 30

    /// Starts a search, cancelling any in flight.
    func run(_ query: String, source: SearchSource, prefs: Preferences, tools: ToolPaths) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        task?.cancel()
        guard !trimmed.isEmpty else { reset(); return }
        resultQuery = trimmed
        resultSource = source
        selection = []
        isSelecting = false
        phase = .loading
        task = Task { [weak self] in
            do {
                let found = try await Discovery.search(trimmed, source: source, limit: Self.resultLimit, prefs: prefs, tools: tools)
                guard !Task.isCancelled else { return }
                self?.results = Self.unique(found)
                self?.phase = .loaded
            } catch DiscoveryError.toolMissing {
                self?.phase = .toolMissing
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if phase == .loading { phase = results.isEmpty ? .idle : .loaded }
    }

    func reset() {
        task?.cancel()
        task = nil
        results = []
        resultQuery = ""
        selection = []
        isSelecting = false
        phase = .idle
    }

    // MARK: Queue + selection

    func markQueued(_ urls: [String]) { queuedURLs.formUnion(urls) }
    func isQueued(_ entry: PlaylistEntry) -> Bool { queuedURLs.contains(entry.url) }

    func toggle(_ entry: PlaylistEntry) {
        if selection.contains(entry.id) { selection.remove(entry.id) } else { selection.insert(entry.id) }
    }

    var selectedEntries: [PlaylistEntry] { results.filter { selection.contains($0.id) } }

    /// Search extractors sometimes repeat an entry; keep the first of each link.
    private static func unique(_ entries: [PlaylistEntry]) -> [PlaylistEntry] {
        var seen = Set<String>()
        return entries.filter { seen.insert($0.url).inserted }
    }
}
