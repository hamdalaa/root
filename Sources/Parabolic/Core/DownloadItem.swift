import Foundation
import Observation

/// Live state of one download. Main-actor only; the UI observes it directly.
@MainActor
@Observable
final class DownloadItem: Identifiable {
    let id: UUID
    var options: DownloadOptions
    var meta: MediaMeta
    var status: DownloadStatus
    /// 0...1, or nil when the size is unknown (indeterminate).
    var progress: Double?
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64?
    /// Bytes per second.
    var speed: Double = 0
    var eta: Int?
    var statusText: String
    var errorMessage: String?
    var filePath: String?
    var addedAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var scheduledAt: Date?
    /// Last ~60 one-second speed samples, for the sparkline.
    var speedSamples: [Double] = []
    /// Raw yt-dlp output (capped).
    private(set) var log: [String] = []
    /// Number of times this item has been (re)started.
    var attempts = 0
    /// Automatic retries used since the last manual start (reset by Retry).
    var autoRetries = 0

    static let maxLogLines = 3000
    static let maxSpeedSamples = 60

    init(id: UUID = UUID(), options: DownloadOptions, meta: MediaMeta, status: DownloadStatus = .queued) {
        self.id = id
        self.options = options
        self.meta = meta
        self.status = status
        self.statusText = status.label
        self.addedAt = Date()
    }

    var title: String { meta.title }
    var platform: Platform { Platform.detect(url: meta.webpageURL ?? options.url, extractor: meta.extractor) }
    var fileURL: URL? { filePath.map { URL(fileURLWithPath: $0) } }
    var fileExists: Bool { filePath.map { FileManager.default.fileExists(atPath: $0) } ?? false }
    var canPause: Bool { status == .running }
    var canResume: Bool { status == .paused }
    var canStop: Bool { status == .running || status == .paused || status == .processing || status == .queued || status == .scheduled }
    var canRetry: Bool { status == .failed || status == .stopped }

    func appendLog(_ line: String) {
        log.append(line)
        if log.count > Self.maxLogLines { log.removeFirst(log.count - Self.maxLogLines) }
    }

    func clearLog() { log.removeAll() }

    var logText: String { log.joined(separator: "\n") }

    func recordSpeedSample() {
        speedSamples.append(status == .running ? speed : 0)
        if speedSamples.count > Self.maxSpeedSamples { speedSamples.removeFirst(speedSamples.count - Self.maxSpeedSamples) }
    }

    func resetForRun() {
        progress = 0
        downloadedBytes = 0
        totalBytes = nil
        speed = 0
        eta = nil
        errorMessage = nil
        filePath = nil
        finishedAt = nil
        speedSamples = []
        startedAt = Date()
        attempts += 1
        statusText = "Starting…"
        clearLog()
    }

    // MARK: - Persistence

    struct Record: Codable {
        var id: UUID
        var options: DownloadOptions
        var meta: MediaMeta
        var status: DownloadStatus
        var errorMessage: String?
        var filePath: String?
        var totalBytes: Int64?
        var addedAt: Date
        var finishedAt: Date?
        var scheduledAt: Date?
    }

    var record: Record {
        var safeOptions = options
        safeOptions.httpHeaders?["Cookie"] = nil
        return Record(id: id, options: safeOptions, meta: meta, status: status, errorMessage: errorMessage, filePath: filePath,
               totalBytes: totalBytes, addedAt: addedAt, finishedAt: finishedAt, scheduledAt: scheduledAt)
    }

    convenience init(record: Record) {
        // Anything that was mid-flight when the app quit comes back stopped, ready to resume.
        let restored: DownloadStatus = switch record.status {
        case .running, .processing, .paused, .queued: .stopped
        default: record.status
        }
        self.init(id: record.id, options: record.options, meta: record.meta, status: restored)
        errorMessage = record.errorMessage
        filePath = record.filePath
        totalBytes = record.totalBytes
        addedAt = record.addedAt
        finishedAt = record.finishedAt
        scheduledAt = record.scheduledAt
        if restored == .completed { progress = 1 }
        statusText = restored == .stopped && record.status != .stopped ? "Interrupted — resume to continue" : restored.label
    }
}
