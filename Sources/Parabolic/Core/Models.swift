import Foundation

// MARK: - Output formats

enum MediaFileType: String, Codable, CaseIterable, Identifiable, Sendable {
    // Video containers
    case mp4, webm, mkv, mov
    // Audio formats
    case mp3, m4a, opus, flac, wav, ogg
    // Keep whatever the site serves, no conversion
    case originalVideo, originalAudio

    var id: String { rawValue }

    var isAudio: Bool {
        switch self {
        case .mp3, .m4a, .opus, .flac, .wav, .ogg, .originalAudio: true
        default: false
        }
    }

    var label: String {
        switch self {
        case .originalVideo: "Original Video"
        case .originalAudio: "Original Audio"
        default: rawValue.uppercased()
        }
    }

    /// File extension yt-dlp will produce, or nil when it depends on the source.
    var fileExtension: String? {
        switch self {
        case .originalVideo, .originalAudio: nil
        default: rawValue
        }
    }

    static let videoTypes: [MediaFileType] = [.mp4, .webm, .mkv, .mov, .originalVideo]
    static let audioTypes: [MediaFileType] = [.mp3, .m4a, .opus, .flac, .wav, .ogg, .originalAudio]
}

enum VideoQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case best, p4320, p2160, p1440, p1080, p720, p480, p360, p240, worst

    var id: String { rawValue }

    var maxHeight: Int? {
        switch self {
        case .p4320: 4320
        case .p2160: 2160
        case .p1440: 1440
        case .p1080: 1080
        case .p720: 720
        case .p480: 480
        case .p360: 360
        case .p240: 240
        case .best, .worst: nil
        }
    }

    var label: String {
        switch self {
        case .best: "Best Available"
        case .worst: "Smallest File"
        case .p4320: "8K (4320p)"
        case .p2160: "4K (2160p)"
        case .p1440: "1440p"
        case .p1080: "1080p"
        case .p720: "720p"
        case .p480: "480p"
        case .p360: "360p"
        case .p240: "240p"
        }
    }
}

enum AudioQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case best, k320, k256, k192, k160, k128, k96

    var id: String { rawValue }

    /// Value passed to `--audio-quality`.
    var ytdlpValue: String {
        switch self {
        case .best: "0"
        case .k320: "320K"
        case .k256: "256K"
        case .k192: "192K"
        case .k160: "160K"
        case .k128: "128K"
        case .k96: "96K"
        }
    }

    var label: String {
        self == .best ? "Best" : ytdlpValue.replacingOccurrences(of: "K", with: " kbps")
    }
}

enum VideoCodec: String, Codable, CaseIterable, Identifiable, Sendable {
    case any, h264, h265, vp9, av1
    var id: String { rawValue }
    var label: String {
        switch self {
        case .any: "Any"
        case .h264: "H.264 (AVC)"
        case .h265: "H.265 (HEVC)"
        case .vp9: "VP9"
        case .av1: "AV1"
        }
    }
    var sortKey: String? {
        switch self {
        case .any: nil
        case .h264: "h264"
        case .h265: "h265"
        case .vp9: "vp9"
        case .av1: "av01"
        }
    }
}

enum AudioCodec: String, Codable, CaseIterable, Identifiable, Sendable {
    case any, aac, opus, mp3, flac, wav
    var id: String { rawValue }
    var label: String { self == .any ? "Any" : rawValue.uppercased() }
    var sortKey: String? { self == .any ? nil : rawValue }
}

enum FrameRate: String, Codable, CaseIterable, Identifiable, Sendable {
    case any, fps24, fps30, fps60
    var id: String { rawValue }
    var label: String {
        switch self {
        case .any: "Any"
        case .fps24: "24 fps"
        case .fps30: "30 fps"
        case .fps60: "60 fps"
        }
    }
    var value: Int? {
        switch self {
        case .any: nil
        case .fps24: 24
        case .fps30: 30
        case .fps60: 60
        }
    }
}

enum SubtitleFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case best, srt, vtt, ass, lrc
    var id: String { rawValue }
    var label: String { self == .best ? "Best Available" : rawValue.uppercased() }
}

enum CookieBrowser: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, safari, chrome, firefox, brave, edge, chromium, opera, vivaldi, whale
    var id: String { rawValue }
    var label: String { self == .none ? "None" : rawValue.capitalized }
}

enum SponsorBlockCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case sponsor, intro, outro, selfpromo, preview, filler, interaction, music_offtopic
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sponsor: "Sponsors"
        case .intro: "Intros"
        case .outro: "Outros / Endcards"
        case .selfpromo: "Self Promotion"
        case .preview: "Previews / Recaps"
        case .filler: "Filler / Tangents"
        case .interaction: "Interaction Reminders"
        case .music_offtopic: "Non-Music Sections"
        }
    }
}

// MARK: - Download state

enum DownloadStatus: String, Codable, Sendable {
    case queued, scheduled, running, processing, paused, completed, failed, stopped

    var isActive: Bool { self == .running || self == .processing || self == .paused }
    var isFinished: Bool { self == .completed || self == .failed || self == .stopped }

    var label: String {
        switch self {
        case .queued: "Queued"
        case .scheduled: "Scheduled"
        case .running: "Downloading"
        case .processing: "Processing"
        case .paused: "Paused"
        case .completed: "Completed"
        case .failed: "Failed"
        case .stopped: "Stopped"
        }
    }
}

struct TimeFrame: Codable, Hashable, Sendable {
    /// Seconds from the start of the media.
    var start: Double
    var end: Double
}

/// Everything needed to start one yt-dlp download. Plain value type so it can be persisted and retried.
struct DownloadOptions: Codable, Hashable, Sendable {
    var url: String
    var fileType: MediaFileType = .mp4
    var videoQuality: VideoQuality = .best
    var audioQuality: AudioQuality = .best
    /// Exact yt-dlp format ids picked in the advanced format list; override quality when set.
    var videoFormatID: String?
    var audioFormatID: String?
    var subtitleLanguages: [String] = []
    var includeAutoSubtitles = false
    var splitChapters = false
    var exportDescription = false
    var saveThumbnailFile = false
    var timeFrame: TimeFrame?
    var liveFromStart = false
    var saveFolder: String
    /// Filename without extension. Empty means use the settings filename template.
    var filename: String = ""
    /// Index inside a playlist URL (adds --playlist-items). Nil downloads the URL as a single item.
    var playlistIndex: Int?
    /// Written as the track number tag when the item came from a playlist.
    var trackNumber: Int?
    var credentialID: UUID?
    /// Tags to write after download (Spotify / Deezer tracks).
    var trackTags: TrackTags?
    var extraArguments: String = ""
    /// Which engine downloads this (nil = media / yt-dlp, for queues saved before engines existed).
    var engine: DownloadEngine?
    /// Browser hand-off headers (Cookie, Referer, User-Agent). Cookies are never written to disk.
    var httpHeaders: [String: String]?
    /// Per-download cap in KB/s (0 = unlimited for this item); nil follows the global limit / schedule.
    var speedLimitKBps: Int?

    var resolvedEngine: DownloadEngine { engine ?? .media }

    init(url: String, saveFolder: String) {
        self.url = url
        self.saveFolder = saveFolder
    }
}

/// Media sites go through yt-dlp; plain files and torrents through aria2 (segmented, resumable).
enum DownloadEngine: String, Codable, CaseIterable, Sendable {
    case media, direct, torrent

    var label: String {
        switch self {
        case .media: "Media"
        case .direct: "File"
        case .torrent: "Torrent"
        }
    }
}

/// What a HEAD probe learned about a plain file link.
struct DirectFileInfo: Codable, Hashable, Sendable {
    var filename: String
    var size: Int64?
    var contentType: String?
    var resumable: Bool
}

/// Display metadata gathered during discovery, carried with the download.
struct MediaMeta: Codable, Hashable, Sendable {
    var title: String
    var uploader: String?
    var duration: Double?
    var thumbnailURL: String?
    var webpageURL: String?
    var extractor: String?
    var isLive = false
}

// MARK: - Discovery results

struct MediaFormat: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var ext: String
    var width: Int?
    var height: Int?
    var fps: Double?
    var vcodec: String?
    var acodec: String?
    var abr: Double?
    var tbr: Double?
    var filesize: Int64?
    var note: String?

    var hasVideo: Bool { (vcodec ?? "none") != "none" }
    var hasAudio: Bool { (acodec ?? "none") != "none" }

    var summary: String {
        var parts: [String] = []
        if hasVideo {
            if let height { parts.append("\(height)p") }
            if let fps, fps > 0 { parts.append("\(Int(fps.rounded()))fps") }
            if let vcodec { parts.append(Self.shortCodec(vcodec)) }
        }
        if hasAudio {
            if let abr, abr > 0 { parts.append("\(Int(abr.rounded())) kbps") }
            if let acodec { parts.append(Self.shortCodec(acodec)) }
        }
        parts.append(ext)
        if let note, !note.isEmpty { parts.append(note) }
        return parts.joined(separator: " · ")
    }

    static func shortCodec(_ codec: String) -> String {
        let head = codec.split(separator: ".").first.map(String.init) ?? codec
        switch head {
        case "avc1", "h264": return "H.264"
        case "hev1", "hvc1", "h265": return "HEVC"
        case "vp09", "vp9": return "VP9"
        case "av01": return "AV1"
        case "mp4a": return "AAC"
        default: return head.uppercased()
        }
    }
}

struct PlaylistEntry: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var index: Int
    var url: String
    var title: String
    var duration: Double?
    var thumbnailURL: String?
    var uploader: String?
    var viewCount: Int?
    /// Original link (e.g. the Spotify track) when `url` is a YouTube Music lookup.
    var sourceURL: String?
    /// Real song tags written after download (Spotify / Deezer).
    var tags: TrackTags?
}

/// Song metadata from Spotify / Deezer, written into the downloaded file.
struct TrackTags: Codable, Hashable, Sendable {
    var title: String
    var artist: String
    var album: String? = nil
    var trackNumber: Int? = nil
    var coverURL: String? = nil

    /// YouTube Music "songs" search for this track; yt-dlp downloads the top match.
    var lookupURL: String {
        var components = URLComponents(string: "https://music.youtube.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: "\(artist) \(title)")]
        return (components.string ?? "https://music.youtube.com/search") + "#songs"
    }
}

struct MediaInfo: Codable, Hashable, Sendable {
    var meta: MediaMeta
    var formats: [MediaFormat] = []
    var subtitleLanguages: [String] = []
    var autoCaptionLanguages: [String] = []
    var chapterCount = 0
    /// Non-empty when the URL is a playlist / channel.
    var entries: [PlaylistEntry] = []
    /// Set when the link is a plain file (aria2 engine) rather than a media page.
    var directFile: DirectFileInfo?
    var engine: DownloadEngine = .media

    var isPlaylist: Bool { !entries.isEmpty }
    var videoFormats: [MediaFormat] { formats.filter(\.hasVideo).sorted { ($0.height ?? 0, $0.tbr ?? 0) > ($1.height ?? 0, $1.tbr ?? 0) } }
    var audioOnlyFormats: [MediaFormat] { formats.filter { $0.hasAudio && !$0.hasVideo }.sorted { ($0.abr ?? 0) > ($1.abr ?? 0) } }
    var availableHeights: Set<Int> { Set(formats.compactMap { $0.hasVideo ? $0.height : nil }) }
}

// MARK: - Presets & history

struct DownloadPreset: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var symbol: String
    var fileType: MediaFileType
    var videoQuality: VideoQuality = .best
    var audioQuality: AudioQuality = .best
    var subtitleLanguages: [String] = []
    var splitChapters = false

    static let builtIn: [DownloadPreset] = [
        DownloadPreset(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Best Video", symbol: "play.rectangle.fill", fileType: .mp4),
        DownloadPreset(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "1080p MP4", symbol: "tv.fill", fileType: .mp4, videoQuality: .p1080),
        DownloadPreset(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, name: "MP3 320", symbol: "music.note", fileType: .mp3, audioQuality: .k320),
        DownloadPreset(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, name: "Lossless FLAC", symbol: "waveform", fileType: .flac),
    ]

    func apply(to options: inout DownloadOptions) {
        options.fileType = fileType
        options.videoQuality = videoQuality
        options.audioQuality = audioQuality
        options.subtitleLanguages = subtitleLanguages
        options.splitChapters = splitChapters
    }
}

struct HistoryEntry: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var url: String
    var title: String
    var uploader: String?
    var thumbnailURL: String?
    var filePath: String?
    var fileType: MediaFileType
    var fileSize: Int64?
    var date: Date

    var platform: Platform { Platform.detect(url: url) }
}

struct Credential: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var username: String
    // Password lives in the Keychain, keyed by id.
}
