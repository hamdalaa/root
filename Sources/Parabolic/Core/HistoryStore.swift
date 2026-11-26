import Foundation
import Observation

@MainActor
@Observable
final class HistoryStore {
    private(set) var entries: [HistoryEntry] = []
    @ObservationIgnored private let fileURL: URL

    init(fileURL: URL = ToolStore.supportDirectory.appendingPathComponent("history.json")) {
        self.fileURL = fileURL
        entries = LossyDecoding.decodeArray(HistoryEntry.self, from: fileURL, decoder: .iso)
    }

    /// The last time this exact link was downloaded, for "already downloaded" warnings.
    func previous(for url: String) -> HistoryEntry? {
        let target = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.first { $0.url == target }
    }

    var totalBytes: Int64 { entries.compactMap(\.fileSize).reduce(0, +) }

    func add(_ entry: HistoryEntry, retention: HistoryRetention) {
        guard retention != .never else { return }
        // One entry per URL + type; re-downloading moves it to the top.
        entries = [entry] + entries.filter { !($0.url == entry.url && $0.fileType == entry.fileType) }
        prune(retention: retention)
    }

    func remove(_ ids: Set<UUID>) {
        entries = entries.filter { !ids.contains($0.id) }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    func prune(retention: HistoryRetention) {
        if let interval = retention.interval {
            let cutoff = Date().addingTimeInterval(-interval)
            entries = entries.filter { $0.date >= cutoff }
        }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder.iso.encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

extension JSONEncoder {
    static let iso: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension JSONDecoder {
    static let iso: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
