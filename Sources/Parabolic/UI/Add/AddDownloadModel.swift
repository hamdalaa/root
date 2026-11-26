import Foundation
import Observation

/// Where the add sheet is in its flow.
enum AddStage: Equatable {
    case input
    case discovering(host: String)
    case failed(message: String)
    case single
    case playlist

    /// Stable key for transitions (ignores associated values).
    var key: Int {
        switch self {
        case .input: 0
        case .discovering: 1
        case .failed: 2
        case .single: 3
        case .playlist: 4
        }
    }
}

/// All state for one pass through the add-download sheet. Views read and bind to it; it never touches the
/// environment objects directly, so callers pass in preferences and tool paths.
@MainActor
@Observable
final class AddDownloadModel {
    // Input
    var urlText = ""
    var inputError: String?
    private(set) var normalizedURL: String?

    // Discovery
    var stage: AddStage = .input
    var credentialID: UUID?
    private(set) var info: MediaInfo?
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?

    // Single-media options
    var options = DownloadOptions(url: "", saveFolder: "")
    var showAdvancedFormats = false
    var trimEnabled = false
    var trimStartText = ""
    var trimEndText = ""
    var startLater = false
    var scheduledAt = Date().addingTimeInterval(3600)

    // Playlist
    var selectedEntryIDs: Set<String> = []
    var entryFilter = ""
    var playlistSubfolder = true
    var numberFiles = false
    var playlistSubtitleText = ""

    // Smart defaults
    /// The site behind the link, from its host or yt-dlp's extractor.
    private(set) var platform: Platform = .other
    /// Set once the user changes the file type or quality themselves; smart defaults never override that.
    private(set) var userTouchedFormat = false
    /// Explains an automatic format choice ("Smart default for SoundCloud"); nil when none was made.
    private(set) var smartDefaultNote: String?
    @ObservationIgnored private var formatBeforeSmartDefault: (MediaFileType, VideoQuality, AudioQuality)?

    // MARK: - Discovery

    var host: String {
        guard let normalizedURL, let host = URL(string: normalizedURL)?.host() else { return "link" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Validates the field and starts yt-dlp. Returns false (and sets `inputError`) when the text isn't a link.
    /// `headers` (browser cookies / referrer) let plain-file probes reach links that need a session.
    @discardableResult
    func startDiscovery(prefs: Preferences, tools: ToolPaths, headers: [String: String]? = nil) -> Bool {
        guard let normalized = Discovery.normalizeURL(urlText) else {
            inputError = urlText.trimmingCharacters(in: .whitespaces).isEmpty
                ? "Paste a link to continue."
                : "That doesn't look like a link. Try something like youtube.com/watch?v=…"
            return false
        }
        inputError = nil
        normalizedURL = normalized
        stage = .discovering(host: host)
        discoveryTask?.cancel()
        let credential = Keychain.resolve(credentialID, in: prefs.credentials)
        discoveryTask = Task { [weak self] in
            do {
                let info: MediaInfo
                if let headers, !headers.isEmpty, EngineRouter.engine(for: normalized) == .direct {
                    info = try await DirectProbe.probe(normalized, headers: headers)
                } else {
                    let found = try await Discovery.discover(url: normalized, prefs: prefs, tools: tools, credential: credential)
                    info = await Self.preferPlainFile(over: found, url: normalized, headers: headers ?? [:])
                }
                guard !Task.isCancelled else { return }
                self?.load(info, prefs: prefs)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self?.stage = .failed(message: error.localizedDescription)
            }
        }
        return true
    }

    /// yt-dlp's generic extractor also "finds" plain files behind redirects (release assets, CDN links).
    /// When the server says it isn't audio, video or a web page, show the file card instead.
    private static func preferPlainFile(over info: MediaInfo, url: String, headers: [String: String]) async -> MediaInfo {
        guard info.engine == .media, !info.isPlaylist, info.meta.extractor?.lowercased() == "generic",
              let probed = try? await DirectProbe.probe(url, headers: headers),
              let type = probed.directFile?.contentType?.lowercased()
        else { return info }
        let isMedia = type.hasPrefix("video/") || type.hasPrefix("audio/") || type.hasPrefix("text/html")
            || type.contains("mpegurl") || type.contains("dash+xml")
        return isMedia ? info : probed
    }

    func cancelDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = nil
        if case .discovering = stage { stage = .input }
    }

    func backToInput() {
        cancelDiscovery()
        stage = .input
    }

    private func load(_ info: MediaInfo, prefs: Preferences) {
        let hadResult = self.info != nil
        self.info = info
        platform = Platform.detect(url: normalizedURL ?? urlText, extractor: info.meta.extractor)
        var opts = DownloadOptions(url: normalizedURL ?? "", saveFolder: prefs.downloadFolder)
        if userTouchedFormat, hadResult {
            // Keep what the user picked for the previous link.
            opts.fileType = options.fileType
            opts.videoQuality = options.videoQuality
            opts.audioQuality = options.audioQuality
        } else {
            opts.fileType = prefs.lastUsedFileType
            opts.videoQuality = prefs.lastUsedVideoQuality
            opts.audioQuality = prefs.lastUsedAudioQuality
        }
        opts.includeAutoSubtitles = prefs.includeAutoSubtitlesByDefault
        opts.filename = info.isPlaylist ? "" : ArgumentBuilder.sanitize(info.directFile?.filename ?? info.meta.title)
        opts.engine = info.engine
        opts.credentialID = credentialID
        opts.liveFromStart = false
        options = opts
        smartDefaultNote = nil
        formatBeforeSmartDefault = nil
        if !userTouchedFormat { applySmartDefault(prefs: prefs) }
        clampQuality()
        trimEnabled = false
        trimStartText = "0:00"
        trimEndText = Format.duration(info.meta.duration) ?? ""
        selectedEntryIDs = Set(info.entries.map(\.id))
        entryFilter = ""
        stage = info.isPlaylist ? .playlist : .single
    }

    // MARK: - Smart defaults

    /// Per-platform preset first, then audio for music platforms. Undoable from the note it leaves.
    private func applySmartDefault(prefs: Preferences) {
        let before = (options.fileType, options.videoQuality, options.audioQuality)
        if let id = prefs.platformPresets[platform.rawValue], let preset = prefs.allPresets.first(where: { $0.id == id }) {
            options.fileType = preset.fileType
            options.videoQuality = preset.videoQuality
            options.audioQuality = preset.audioQuality
            smartDefaultNote = "Your \(platform.title) preset, \(preset.name)"
        } else if platform.prefersAudio, prefs.smartAudioForMusicPlatforms, !options.fileType.isAudio {
            options.fileType = .mp3
            smartDefaultNote = "Smart default for \(platform.title): audio as MP3"
        } else {
            return
        }
        if before != (options.fileType, options.videoQuality, options.audioQuality) {
            formatBeforeSmartDefault = before
        } else {
            smartDefaultNote = nil
        }
    }

    /// Puts back the format that was in place before the smart default.
    func undoSmartDefault() {
        if let (type, video, audio) = formatBeforeSmartDefault {
            options.fileType = type
            options.videoQuality = video
            options.audioQuality = audio
            options.videoFormatID = nil
            clampQuality()
        }
        formatBeforeSmartDefault = nil
        smartDefaultNote = nil
        userTouchedFormat = true
    }

    /// Called whenever the user changes type, quality or a preset by hand.
    func markFormatTouched() {
        userTouchedFormat = true
        smartDefaultNote = nil
        formatBeforeSmartDefault = nil
    }

    // MARK: - Format helpers

    var isAudio: Bool {
        get { options.fileType.isAudio }
        set {
            guard newValue != options.fileType.isAudio else { return }
            options.fileType = newValue ? .mp3 : .mp4
            options.videoFormatID = nil
        }
    }

    /// Qualities the source can actually deliver, plus Best and Smallest.
    var availableQualities: [VideoQuality] {
        guard let maxHeight = info?.availableHeights.max() else { return VideoQuality.allCases }
        return VideoQuality.allCases.filter { quality in
            guard let height = quality.maxHeight else { return true }
            return height <= maxHeight
        }
    }

    func clampQuality() {
        if !availableQualities.contains(options.videoQuality) { options.videoQuality = .best }
    }

    func apply(_ preset: DownloadPreset) {
        preset.apply(to: &options)
        options.videoFormatID = nil
        options.audioFormatID = nil
        clampQuality()
    }

    /// A preset reads as applied while the current options still match it.
    func matches(_ preset: DownloadPreset) -> Bool {
        options.fileType == preset.fileType
            && options.videoQuality == preset.videoQuality
            && options.audioQuality == preset.audioQuality
    }

    /// Best guess at the final size from the formats yt-dlp would pick, scaled to the trimmed section.
    /// Nil when the site gave neither sizes nor bitrates.
    var estimatedSize: Int64? {
        guard let full = fullEstimatedSize else { return nil }
        if case .success(let frame?) = trimResult, let duration = info?.meta.duration, duration > 0 {
            return Int64(Double(full) * min(1, (frame.end - frame.start) / duration))
        }
        return full
    }

    /// Reported size, or bitrate × duration when the site only gives a bitrate (tbr is in kbit/s).
    private func size(of format: MediaFormat?) -> Int64? {
        guard let format else { return nil }
        if let filesize = format.filesize, filesize > 0 { return filesize }
        guard let tbr = format.tbr, tbr > 0, let duration = info?.meta.duration, duration > 0 else { return nil }
        return Int64(tbr * 125 * duration)
    }

    private var fullEstimatedSize: Int64? {
        guard let info else { return nil }
        let audio = info.audioOnlyFormats.first { $0.id == options.audioFormatID } ?? info.audioOnlyFormats.first
        if options.fileType.isAudio {
            return size(of: audio) ?? info.formats.filter(\.hasAudio).compactMap { size(of: $0) }.max()
        }
        let video: MediaFormat?
        if let id = options.videoFormatID {
            video = info.videoFormats.first { $0.id == id }
        } else {
            let fitting = info.videoFormats.filter { format in
                guard let limit = options.videoQuality.maxHeight else { return true }
                return (format.height ?? 0) <= limit
            }
            video = options.videoQuality == .worst ? fitting.last : fitting.first
        }
        guard let video, let videoSize = size(of: video) else { return nil }
        if video.hasAudio { return videoSize }
        return videoSize + (size(of: audio) ?? 0)
    }

    // MARK: - Subtitles

    func subtitleChoices(includeAuto: Bool) -> [String] {
        guard let info else { return [] }
        var seen = Set<String>()
        let all = info.subtitleLanguages + (includeAuto ? info.autoCaptionLanguages : [])
        return all.filter { seen.insert($0).inserted }
    }

    func toggleSubtitle(_ code: String) {
        if let index = options.subtitleLanguages.firstIndex(of: code) {
            options.subtitleLanguages.remove(at: index)
        } else {
            options.subtitleLanguages.append(code)
        }
    }

    // MARK: - Trim

    /// The validated time frame, or an error message for the trim card.
    var trimResult: Result<TimeFrame?, TrimError> {
        guard trimEnabled else { return .success(nil) }
        guard let start = TimeParser.seconds(from: trimStartText) else { return .failure(.init("Start time isn't valid. Use 1:23, 1:02:03 or seconds.")) }
        guard let end = TimeParser.seconds(from: trimEndText) else { return .failure(.init("End time isn't valid. Use 1:23, 1:02:03 or seconds.")) }
        guard end > start else { return .failure(.init("End must be after the start.")) }
        if let duration = info?.meta.duration, duration > 0, end > duration + 0.5 {
            return .failure(.init("End is past the end of the video (\(Format.duration(duration) ?? "")).") )
        }
        return .success(TimeFrame(start: start, end: end))
    }

    var trimError: String? {
        if case .failure(let error) = trimResult { return error.message }
        return nil
    }

    // MARK: - Playlist

    var filteredEntries: [PlaylistEntry] {
        guard let entries = info?.entries else { return [] }
        let query = entryFilter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.title.localizedCaseInsensitiveContains(query) || "\($0.index)" == query }
    }

    var selectedEntries: [PlaylistEntry] {
        (info?.entries ?? []).filter { selectedEntryIDs.contains($0.id) }.sorted { $0.index < $1.index }
    }

    /// Options for one playlist entry, built from the shared options.
    func options(for entry: PlaylistEntry, playlistTitle: String, totalCount: Int) -> DownloadOptions {
        var opts = options
        opts.url = entry.url
        opts.trackTags = entry.tags
        opts.videoFormatID = nil
        opts.audioFormatID = nil
        opts.credentialID = credentialID
        opts.subtitleLanguages = playlistSubtitleText
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if playlistSubfolder {
            let name = ArgumentBuilder.sanitize(playlistTitle).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { opts.saveFolder = (opts.saveFolder as NSString).appendingPathComponent(name) }
        }
        if numberFiles {
            let width = totalCount >= 100 ? 3 : 2
            let number = String(format: "%0\(width)d", entry.index)
            opts.filename = "\(number) - \(ArgumentBuilder.sanitize(entry.title))"
            opts.trackNumber = entry.index
        } else {
            opts.filename = ""
        }
        return opts
    }
}

struct TrimError: Error, Equatable {
    var message: String
    init(_ message: String) { self.message = message }
}

/// Parses "83", "1:23", "1:02:03" (and decimals) into seconds.
enum TimeParser {
    static func seconds(from text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for (offset, part) in parts.enumerated() {
            guard let value = Double(part), value >= 0 else { return nil }
            // Minutes and seconds fields (not the leading one) must be under 60.
            if offset > 0, value >= 60 { return nil }
            total = total * 60 + value
        }
        return total
    }
}
