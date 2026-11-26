import AppKit
import Foundation
import Observation

/// Owns the queue: concurrency, lifecycle, persistence, history and system hooks.
@MainActor
@Observable
final class DownloadManager {
    private(set) var items: [DownloadItem] = []

    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let tools: ToolStore
    @ObservationIgnored let history: HistoryStore
    @ObservationIgnored let system: SystemIntegration
    @ObservationIgnored private var runners: [UUID: ProcessRunner] = [:]
    @ObservationIgnored private var secrets: [UUID: [String]] = [:]
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var saveWorkItem: DispatchWorkItem?
    @ObservationIgnored private var completedSinceIdle = 0
    /// Quick downloads still fetching title/artwork; held back from the queue until resolved.
    @ObservationIgnored private var awaitingInfo = Set<UUID>()
    /// Items the user restarted while their previous process was still exiting.
    @ObservationIgnored private var restartAfterExit = Set<UUID>()
    @ObservationIgnored private var lastGlobalLimit: Int?
    /// At most this many yt-dlp lookups at once for quick / batch downloads.
    @ObservationIgnored private let discoveryGate = AsyncGate(limit: 3)
    @ObservationIgnored private let queueURL = ToolStore.supportDirectory.appendingPathComponent("queue.json")

    /// Global speed samples (bytes/s), one per second, for the toolbar sparkline.
    private(set) var totalSpeedSamples: [Double] = []

    init(settings: AppSettings, tools: ToolStore, history: HistoryStore, system: SystemIntegration) {
        self.settings = settings
        self.tools = tools
        self.history = history
        self.system = system
        restore()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private var prefs: Preferences { settings.prefs }

    // MARK: - Derived state

    var activeItems: [DownloadItem] { items.filter { $0.status.isActive } }
    var queuedItems: [DownloadItem] { items.filter { $0.status == .queued || $0.status == .scheduled } }
    var completedItems: [DownloadItem] { items.filter { $0.status == .completed } }
    var failedItems: [DownloadItem] { items.filter { $0.status == .failed || $0.status == .stopped } }
    var runningCount: Int { items.filter { $0.status == .running || $0.status == .processing }.count }
    var totalSpeed: Double { items.filter { $0.status == .running }.reduce(0) { $0 + $1.speed } }

    /// Average progress across active items, nil when idle.
    var overallProgress: Double? {
        let active = activeItems
        guard !active.isEmpty else { return nil }
        return active.reduce(0) { $0 + ($1.progress ?? 0) } / Double(active.count)
    }

    func item(_ id: UUID) -> DownloadItem? { items.first { $0.id == id } }

    /// Item count per platform (only platforms that appear), most used first.
    var platformCounts: [(platform: Platform, count: Int)] {
        Dictionary(grouping: items, by: \.platform)
            .map { (platform: $0.key, count: $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.platform.title < $1.platform.title }
    }

    // MARK: - Adding

    @discardableResult
    func enqueue(options: DownloadOptions, meta: MediaMeta, scheduledAt: Date? = nil) -> DownloadItem {
        let item = DownloadItem(options: options, meta: meta, status: scheduledAt == nil ? .queued : .scheduled)
        item.scheduledAt = scheduledAt
        if let scheduledAt { item.statusText = "Starts \(scheduledAt.formatted(date: .omitted, time: .shortened))" }
        items.insert(item, at: 0)
        settings.prefs.lastUsedFileType = options.fileType
        pump()
        scheduleSave()
        return item
    }

    /// One-click download with a preset: enqueues immediately, fills in title/artwork in the background,
    /// and expands playlists into one item per entry.
    /// The download already running or waiting for this link or filename (another mirror of the same file
    /// counts too). Starting it twice only splits the connection, making both slower.
    func activeDuplicate(url: String, filename: String?) -> DownloadItem? {
        let name = (filename ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return items.first { item in
            guard item.status.isActive || item.status == .queued || item.status == .scheduled else { return false }
            if item.options.url == url { return true }
            guard !name.isEmpty else { return false }
            return item.options.filename.lowercased() == name || item.title.lowercased() == name
        }
    }

    /// A file the browser handed over: always the file engine (aria2) with the browser's cookies, never yt-dlp.
    /// If the same file is already downloading, that download is returned instead of starting a second copy.
    @discardableResult
    func enqueueFile(url: String, filename: String?, headers: [String: String]?, folder: String? = nil,
                     size: Int64? = nil, scheduledAt: Date? = nil) -> DownloadItem? {
        guard let normalized = Discovery.normalizeURL(url) else { return nil }
        if let existing = activeDuplicate(url: normalized, filename: filename) { return existing }
        var options = DownloadOptions(url: normalized, saveFolder: folder ?? prefs.downloadFolder)
        options.engine = EngineRouter.engine(for: normalized) == .torrent ? .torrent : .direct
        options.httpHeaders = headers
        options.filename = ArgumentBuilder.sanitize(filename ?? "")
        let name = options.filename.isEmpty ? (URL(string: normalized)?.lastPathComponent ?? "Download") : options.filename
        let item = enqueue(options: options,
                           meta: MediaMeta(title: name, uploader: URL(string: normalized)?.host, webpageURL: normalized, extractor: "File"),
                           scheduledAt: scheduledAt)
        if let size, item.totalBytes == nil { item.totalBytes = size }
        return item
    }

    @discardableResult
    func quickDownload(url: String, preset: DownloadPreset? = nil, headers: [String: String]? = nil, filename: String? = nil,
                       folder: String? = nil) -> DownloadItem? {
        guard let normalized = Discovery.normalizeURL(url) else { return nil }
        var options = DownloadOptions(url: normalized, saveFolder: folder ?? prefs.downloadFolder)
        options.engine = EngineRouter.engine(for: normalized)
        options.httpHeaders = headers
        if let filename, options.resolvedEngine == .direct { options.filename = filename }
        (preset ?? prefs.preset(for: Platform.detect(url: normalized))).apply(to: &options)
        options.includeAutoSubtitles = prefs.includeAutoSubtitlesByDefault
        let placeholder = MediaMeta(title: URL(string: normalized)?.host ?? normalized, webpageURL: normalized)
        let item = DownloadItem(options: options, meta: placeholder, status: .queued)
        item.statusText = "Fetching info…"
        items.insert(item, at: 0)
        awaitingInfo.insert(item.id)
        scheduleSave()

        let prefsSnapshot = prefs, toolsSnapshot = tools.paths
        let credential = Keychain.resolve(options.credentialID, in: prefs.credentials)
        Task {
            let info = await self.discoveryGate.run {
                try? await Discovery.discover(url: normalized, prefs: prefsSnapshot, tools: toolsSnapshot,
                                              credential: credential, singleVideo: Self.isWatchLink(normalized))
            }
            self.awaitingInfo.remove(item.id)
            guard let current = self.item(item.id), current.status == .queued else { self.pump(); return }
            if let info, info.isPlaylist {
                self.items.removeAll { $0.id == item.id }
                for entry in info.entries.reversed() where Discovery.normalizeURL(entry.url) != nil {
                    var entryOptions = options
                    entryOptions.url = entry.url
                    entryOptions.trackNumber = entry.index
                    entryOptions.trackTags = entry.tags
                    let meta = MediaMeta(title: entry.title, uploader: info.meta.uploader, duration: entry.duration,
                                         thumbnailURL: entry.thumbnailURL, webpageURL: entry.sourceURL ?? entry.url, extractor: info.meta.extractor)
                    self.items.insert(DownloadItem(options: entryOptions, meta: meta), at: 0)
                }
            } else if let info {
                current.meta = info.meta
                current.options.engine = info.engine
                current.statusText = DownloadStatus.queued.label
            } else {
                current.statusText = DownloadStatus.queued.label
            }
            self.pump()
            self.scheduleSave()
        }
        return item
    }

    // MARK: - Controls

    func pause(_ item: DownloadItem) {
        guard item.status == .running, let runner = runners[item.id] else { return }
        runner.suspend()
        item.status = .paused
        item.speed = 0
        item.statusText = "Paused"
        // Don't pump(): pausing must not start other queued downloads (Pause All would never pause).
        system.update(manager: self)
    }

    func resume(_ item: DownloadItem) {
        switch item.status {
        case .paused:
            runners[item.id]?.resume()
            item.status = .running
            item.statusText = "Resuming…"
        case .stopped, .failed:
            retry(item)
        case .scheduled:
            item.scheduledAt = nil
            item.status = .queued
            pump()
        default:
            break
        }
        system.update(manager: self)
    }

    func stop(_ item: DownloadItem) {
        if let runner = runners[item.id] {
            item.status = .stopped
            item.statusText = "Stopping…"
            runner.terminate()
        } else if item.status == .queued || item.status == .scheduled {
            item.status = .stopped
            item.statusText = DownloadStatus.stopped.label
            scheduleSave()
        }
    }

    func retry(_ item: DownloadItem) {
        guard item.canRetry || item.status == .completed else { return }
        // Still shutting down: restart once the old process has actually exited.
        if runners[item.id] != nil {
            restartAfterExit.insert(item.id)
            item.statusText = "Restarting…"
            return
        }
        item.autoRetries = 0
        item.status = .queued
        item.statusText = DownloadStatus.queued.label
        item.errorMessage = nil
        item.progress = 0
        pump()
        scheduleSave()
    }

    func startNow(_ item: DownloadItem) {
        guard item.status == .queued || item.status == .scheduled || item.canRetry else { return }
        guard runners[item.id] == nil else { restartAfterExit.insert(item.id); return }
        item.scheduledAt = nil
        start(item)
    }

    func remove(_ item: DownloadItem, deleteFile: Bool = false) {
        if runners[item.id] != nil { stop(item) }
        if deleteFile, let url = item.fileURL { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        items.removeAll { $0.id == item.id }
        scheduleSave()
        system.update(manager: self)
    }

    func remove(ids: Set<UUID>) {
        for item in items where ids.contains(item.id) { remove(item) }
    }

    /// Sets a per-download cap (nil = follow global). Running downloads restart to apply it; both engines resume.
    func setSpeedLimit(_ item: DownloadItem, kbps: Int?) {
        guard item.options.speedLimitKBps != kbps else { return }
        item.options.speedLimitKBps = kbps
        scheduleSave()
        restartIfRunning(item)
    }

    private func restartIfRunning(_ item: DownloadItem) {
        guard runners[item.id] != nil, item.status == .running || item.status == .paused else { return }
        restartAfterExit.insert(item.id)
        item.status = .stopped
        item.statusText = "Applying speed limit…"
        runners[item.id]?.terminate()
    }

    func pauseAll() { activeItems.filter(\.canPause).forEach(pause) }
    func resumeAll() {
        items.filter { $0.status == .paused || $0.status == .stopped }.forEach(resume)
    }
    func stopAll() { items.filter(\.canStop).forEach(stop) }
    func retryFailed() { items.filter { $0.status == .failed }.forEach(retry) }
    /// Completed items only: failed and interrupted items keep their resume path (and .part files).
    func clearFinished() {
        items.removeAll { $0.status == .completed }
        scheduleSave()
    }
    func clearCompleted() {
        items.removeAll { $0.status == .completed }
        scheduleSave()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        scheduleSave()
    }

    // MARK: - Engine

    /// Starts queued items until the concurrency limit is reached. Oldest queued first.
    func pump() {
        let limit = max(1, prefs.maxConcurrentDownloads)
        var running = runningCount
        for item in items.reversed() where item.status == .queued && !awaitingInfo.contains(item.id) {
            guard running < limit else { break }
            start(item)
            running += 1
        }
        system.update(manager: self)
    }

    private func start(_ item: DownloadItem) {
        // A URL that looks like a flag must never reach yt-dlp/aria2 argv.
        guard !item.options.url.hasPrefix("-") else {
            fail(item, message: "That link isn't valid.")
            return
        }
        let engine = item.options.resolvedEngine
        let executable: String
        let args: [String]
        try? FileManager.default.createDirectory(atPath: item.options.saveFolder, withIntermediateDirectories: true)
        let credential = Keychain.resolve(item.options.credentialID, in: prefs.credentials)
        let cookie = item.options.httpHeaders?["Cookie"]
        secrets[item.id] = ([credential?.password, cookie].compactMap { $0 }).filter { !$0.isEmpty }
        if engine == .media {
            guard let ytdlp = tools.paths.ytdlp else {
                fail(item, message: DiscoveryError.toolMissing.localizedDescription)
                return
            }
            executable = ytdlp
            args = ArgumentBuilder.download(options: item.options, prefs: prefs, tools: tools.paths, credential: credential)
        } else {
            guard let aria2 = tools.paths.aria2c else {
                fail(item, message: "The file engine (aria2) is missing. Reinstall Root.")
                return
            }
            executable = aria2
            args = ArgumentBuilder.aria2(options: item.options, prefs: prefs)
        }

        item.resetForRun()
        item.status = .running
        let id = item.id
        do {
            runners[id] = try ProcessRunner(
                executable: executable, arguments: args, environment: ["PATH": tools.paths.childPATH],
                onLine: { [weak self] line in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(line: line, for: id) } }
                },
                onExit: { [weak self] code in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.finish(id: id, exitCode: code) } }
                })
        } catch {
            fail(item, message: error.localizedDescription)
        }
        scheduleSave()
    }

    private func handle(line: String, for id: UUID) {
        guard let item = item(id) else { return }
        var safe = line
        for secret in secrets[id] ?? [] { safe = safe.replacingOccurrences(of: secret, with: "••••••") }
        item.appendLog(safe)
        guard item.status != .stopped else { return }

        switch ProgressParser.parse(line) {
        case let .downloading(fraction, downloaded, total, speed, eta):
            if item.status == .paused { return }
            item.status = .running
            item.progress = fraction
            item.downloadedBytes = downloaded
            if let total { item.totalBytes = total }
            item.speed = speed ?? 0
            item.eta = eta
            item.statusText = "Downloading"
        case .processing(let label):
            item.status = .processing
            item.progress = nil
            item.speed = 0
            item.eta = nil
            item.statusText = label
        case .finalFile(let path):
            item.filePath = path
        case .sleeping(let seconds):
            item.statusText = "Waiting \(Int(seconds))s (rate limit)…"
        case .error(let message):
            item.errorMessage = message
        case .log:
            if line.hasPrefix("[download] Destination:"), item.meta.title.hasPrefix("http") || item.meta.title == item.meta.webpageURL {
                let path = line.dropFirst("[download] Destination:".count).trimmingCharacters(in: .whitespaces)
                item.meta.title = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            }
        }
    }

    private func finish(id: UUID, exitCode: Int32) {
        runners[id] = nil
        secrets[id] = nil
        if restartAfterExit.remove(id) != nil, let item = item(id) {
            item.status = .stopped
            retry(item)
            return
        }
        guard let item = item(id) else { pump(); return }
        item.speed = 0
        item.eta = nil
        item.finishedAt = Date()

        if item.status == .stopped {
            item.statusText = DownloadStatus.stopped.label
        } else if exitCode == 0, let tags = item.options.trackTags, let path = item.filePath, let ffmpeg = tools.paths.ffmpeg {
            // Spotify / Deezer: write the real song tags and cover before calling it done.
            item.status = .processing
            item.progress = nil
            item.statusText = "Writing song tags…"
            Task {
                await MusicTagger.apply(tags, to: path, ffmpeg: ffmpeg)
                guard self.item(item.id) != nil else { return } // removed while tagging
                self.complete(item)
                self.pump()
                self.scheduleSave()
                self.checkIdle()
            }
            return
        } else if exitCode == 0 {
            complete(item)
        } else {
            let message = item.errorMessage ?? Discovery.cleanError(item.logText) ?? "yt-dlp exited with code \(exitCode)."
            fail(item, message: message)
        }
        pump()
        scheduleSave()
        checkIdle()
    }

    /// Moves a finished file (or torrent folder) into its category subfolder and returns the new path.
    private func sortIntoCategory(_ item: DownloadItem, path: String) -> String {
        let fm = FileManager.default
        let base = (item.options.saveFolder as NSString).standardizingPath
        let standardized = (path as NSString).standardizingPath
        // For torrents, move the top-level entry inside the save folder; otherwise the file itself.
        var source = standardized
        if item.options.resolvedEngine == .torrent, standardized.hasPrefix(base + "/") {
            let first = standardized.dropFirst(base.count + 1).split(separator: "/").first.map(String.init) ?? ""
            source = (base as NSString).appendingPathComponent(first)
        }
        let category = FileCategory.of(filename: (source as NSString).lastPathComponent,
                                       engine: item.options.resolvedEngine, fileType: item.options.fileType)
        let folder = (base as NSString).appendingPathComponent(category.rawValue)
        guard (source as NSString).deletingLastPathComponent != folder else { return path }
        try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        var target = (folder as NSString).appendingPathComponent((source as NSString).lastPathComponent)
        var n = 2
        let stem = ((source as NSString).lastPathComponent as NSString).deletingPathExtension
        let ext = (source as NSString).pathExtension
        while fm.fileExists(atPath: target) {
            target = (folder as NSString).appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        }
        guard (try? fm.moveItem(atPath: source, toPath: target)) != nil else { return path }
        return source == standardized ? target : (target as NSString).appendingPathComponent(String(standardized.dropFirst(source.count + 1)))
    }

    private func complete(_ item: DownloadItem) {
        if prefs.organizeByType, let path = item.filePath, FileManager.default.fileExists(atPath: path) {
            item.filePath = sortIntoCategory(item, path: path)
        }
        if prefs.autoExtractArchives, item.options.resolvedEngine == .direct, let path = item.filePath,
           ArchiveExtractor.canExtract(path) {
            Task { [weak item] in
                guard let item, let folder = await ArchiveExtractor.extract(path) else { return }
                item.statusText = "Extracted to \((folder as NSString).lastPathComponent)"
            }
        }
        if item.options.resolvedEngine != .media, prefs.quarantineDownloads, let path = item.filePath {
            if item.options.resolvedEngine == .torrent {
                Quarantine.markTree(path, within: item.options.saveFolder)
            } else {
                Quarantine.mark(path)
            }
        }
        item.status = .completed
        item.progress = 1
        item.statusText = DownloadStatus.completed.label
        if let path = item.filePath,
           let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 {
            item.totalBytes = size
        }
        let link = ArgumentBuilder.isMusicLookup(item.options.url) ? (item.meta.webpageURL ?? item.options.url) : item.options.url
        history.add(HistoryEntry(url: link, title: item.title, uploader: item.meta.uploader,
                                 thumbnailURL: item.meta.thumbnailURL, filePath: item.filePath,
                                 fileType: item.options.fileType, fileSize: item.totalBytes, date: Date()),
                    retention: prefs.historyRetention)
        completedSinceIdle += 1
        if prefs.showNotifications { system.notifyCompleted(item) }
    }

    private func fail(_ item: DownloadItem, message: String) {
        if item.autoRetries < prefs.autoRetryAttempts, Self.isTransient(message) {
            // Back off a little longer each time, then go back into the queue.
            item.autoRetries += 1
            let delay = TimeInterval(5 * item.autoRetries)
            item.status = .scheduled
            item.scheduledAt = Date().addingTimeInterval(delay)
            item.errorMessage = message
            item.statusText = "Retrying in \(Int(delay))s…"
            item.speed = 0
            return
        }
        item.status = .failed
        item.errorMessage = message
        item.statusText = DownloadStatus.failed.label
        item.speed = 0
        if prefs.showNotifications { system.notifyFailed(item) }
    }

    /// `watch?v=X&list=…`: a quick download means this video, not the whole mix/playlist.
    nonisolated static func isWatchLink(_ url: String) -> Bool {
        URLComponents(string: url)?.queryItems?.contains { $0.name == "v" } ?? false
    }

    /// Network hiccups are worth retrying; missing pages, logins and unsupported links are not.
    nonisolated static func isTransient(_ message: String) -> Bool {
        let lower = message.lowercased()
        let permanent = ["unsupported url", "404", "not found", "private", "sign in", "login", "members", "copyright",
                         "unavailable", "removed", "is missing", "invalid", "drm"]
        if permanent.contains(where: lower.contains) { return false }
        let transient = ["timed out", "timeout", "403", "429", "500", "502", "503", "504", "connection", "network",
                         "reset", "temporarily", "eof", "ssl", "unable to download", "download aborted", "aborted"]
        return transient.contains(where: lower.contains)
    }

    private func checkIdle() {
        guard runners.isEmpty,
              !items.contains(where: { $0.status == .queued || $0.status == .scheduled || $0.status == .processing }) else { return }
        defer { completedSinceIdle = 0 }
        guard completedSinceIdle > 0 else { return }
        system.runCompletionAction(prefs.completionAction)
    }

    private func tick() {
        let now = Date()
        var promoted = false
        for item in items where item.status == .scheduled {
            if let at = item.scheduledAt, at <= now {
                item.status = .queued
                item.scheduledAt = nil
                item.statusText = DownloadStatus.queued.label
                promoted = true
            }
        }
        if promoted { pump() }
        // Bandwidth schedule boundary: restart transfers that follow the global cap so the new cap applies.
        let globalLimit = prefs.effectiveSpeedLimitKBps(at: now)
        if let previous = lastGlobalLimit, previous != globalLimit {
            for item in items where item.status == .running && item.options.speedLimitKBps == nil { restartIfRunning(item) }
        }
        lastGlobalLimit = globalLimit
        for item in items where item.status.isActive { item.recordSpeedSample() }
        totalSpeedSamples.append(totalSpeed)
        if totalSpeedSamples.count > 60 { totalSpeedSamples.removeFirst(totalSpeedSamples.count - 60) }
        system.update(manager: self)
        writeLiveStatus()
    }

    @ObservationIgnored private var lastLiveSignature = ""
    @ObservationIgnored private let liveURL = ToolStore.supportDirectory.appendingPathComponent("live.json")

    /// Small snapshot for the browser extension popup (read by ParabolicHost): progress and speed per item.
    private func writeLiveStatus() {
        let snapshot: [[String: Any]] = items.prefix(12).map { item in
            [
                "title": item.title,
                "status": item.status.rawValue,
                "statusText": item.statusText,
                "progress": item.progress ?? -1,
                "speed": item.speed,
                "eta": item.eta ?? -1,
                "url": item.meta.webpageURL ?? item.options.url,
                "thumbnail": item.meta.thumbnailURL ?? "",
                "platform": item.platform.rawValue,
            ]
        }
        let signature = snapshot.map { "\($0["status"]!)\($0["progress"]!)\($0["speed"]!)" }.joined()
        guard signature != lastLiveSignature || runningCount > 0 else { return }
        lastLiveSignature = signature
        let payload: [String: Any] = ["updated": Date().timeIntervalSince1970, "items": snapshot]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: liveURL, options: .atomic)
        }
    }

    // MARK: - Persistence

    private func restore() {
        let records = LossyDecoding.decodeArray(DownloadItem.Record.self, from: queueURL, decoder: .iso)
        items = records.map(DownloadItem.init(record:))
    }

    func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveNow() } }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveNow() {
        // Keep everything unfinished plus the latest 200 completed items.
        var completedKept = 0
        let records = items.compactMap { item -> DownloadItem.Record? in
            if item.status == .completed {
                completedKept += 1
                if completedKept > 200 { return nil }
            }
            return item.record
        }
        if let data = try? JSONEncoder.iso.encode(records) {
            try? data.write(to: queueURL, options: .atomic)
        }
    }

    /// Stops every process; called on quit.
    func shutdown() {
        saveNow()
        runners.values.forEach { $0.terminate() }
    }
}
