import Foundation
import Observation

enum AppearanceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum HistoryRetention: String, Codable, CaseIterable, Identifiable, Sendable {
    case never, day, week, month, forever
    var id: String { rawValue }
    var label: String {
        switch self {
        case .never: "Don't keep history"
        case .day: "One day"
        case .week: "One week"
        case .month: "One month"
        case .forever: "Forever"
        }
    }
    var interval: TimeInterval? {
        switch self {
        case .never: 0
        case .day: 86_400
        case .week: 604_800
        case .month: 2_592_000
        case .forever: nil
        }
    }
}

enum CompletionAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case nothing, notify, quit, sleep
    var id: String { rawValue }
    var label: String {
        switch self {
        case .nothing: "Do nothing"
        case .notify: "Play a sound"
        case .quit: "Quit Root"
        case .sleep: "Put Mac to sleep"
        }
    }
}

enum YtdlpChannel: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Prefer the app-managed copy, fall back to one on PATH (Homebrew etc).
    case automatic
    /// Always use the copy found on PATH.
    case system
    var id: String { rawValue }
    var label: String { self == .automatic ? "Managed by Root" : "System (Homebrew / PATH)" }
}

/// Every user preference. New fields must have defaults; missing keys fall back on load.
struct Preferences: Codable, Equatable, Sendable {
    // General
    var appearance: AppearanceMode = .system
    var showMenuBarExtra = true
    var watchClipboard = true
    var showNotifications = true
    var preventSleep = true
    var showDockProgress = true
    var confirmQuitWithActiveDownloads = true
    var historyRetention: HistoryRetention = .month
    var completionAction: CompletionAction = .notify
    var defaultPresetID: UUID? = DownloadPreset.builtIn.first?.id

    // Downloads
    var downloadFolder: String = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()
    var filenameTemplate = "%(title)s"
    var organizeByUploader = false
    var maxConcurrentDownloads = 3
    var overwriteExistingFiles = false
    var usePartFiles = true
    var limitFilenameCharacters = false
    var includeMediaIDInTitle = false
    var speedLimitKBps = 0
    var retries = 10
    var concurrentFragments = 8
    /// Media downloads use the bundled aria2 for multi-connection HTTP (HLS/DASH stay on yt-dlp's native fragments).
    var useAria2 = true
    /// Turbo: maximum connections and fragments, bigger disk cache. Uses more bandwidth and server slots.
    var turboMode = false
    /// Sort finished files into Video / Music / Documents / Archives / Apps / Images / Torrents subfolders.
    var organizeByType = false
    /// Unpack .zip / .tar.* archives after they finish downloading.
    var autoExtractArchives = false
    var aria2MaxConnections = 16
    var sponsorBlockEnabled = false
    var sponsorBlockCategories: [SponsorBlockCategory] = [.sponsor, .selfpromo, .interaction]
    var autoStartFromClipboard = false

    // Converter
    var preferredVideoCodec: VideoCodec = .any
    var preferredAudioCodec: AudioCodec = .any
    var preferredFrameRate: FrameRate = .any
    var embedMetadata = true
    var embedThumbnail = true
    var cropAudioThumbnails = true
    var embedSubtitles = true
    var embedChapters = true
    var removeSourceData = false
    var subtitleFormat: SubtitleFormat = .srt
    var includeAutoSubtitlesByDefault = false
    var postprocessingThreads = 0

    // Network
    var proxyURL = ""
    var cookieBrowser: CookieBrowser = .none
    var cookiesFilePath = ""
    var userAgent = ""
    var forceIPv4 = false
    var sleepBetweenRequests = 0

    // Advanced
    var ytdlpChannel: YtdlpChannel = .automatic
    var useNightlyBuilds = false
    var extraDownloadArguments = ""
    var extraDiscoveryArguments = ""
    var metadataLanguage = ""

    // Platforms & automation
    /// Platform rawValue → preset id used for quick downloads from that platform.
    var platformPresets: [String: UUID] = [:]
    /// Quick downloads from music/podcast platforms default to audio when no platform preset is set.
    var smartAudioForMusicPlatforms = true
    var showPlatformsInSidebar = true
    var globalHotKeyEnabled = true
    /// ⌃⌥⌘⎋ opens Force Quit Applications from any app.
    var forceQuitHotKeyEnabled = true
    /// Last setup-guide version the user finished (see `SetupGuide.currentVersion`).
    var setupGuideVersion = 0
    var subscriptionsEnabled = true
    var subscriptionCheckMinutes = 60

    // Bandwidth schedule: a different global cap during set hours (e.g. work hours).
    var bandwidthScheduleEnabled = false
    var bandwidthScheduleStartHour = 9
    var bandwidthScheduleEndHour = 18
    var bandwidthScheduleLimitKBps = 512
    var bandwidthScheduleWeekdaysOnly = true

    // Browser extension & file engine
    var browserCatchDownloads = true
    /// Catch every browser download (images, small files) instead of only the listed types.
    var browserCatchEverything = false
    /// FDM-style window for each caught download (name, size, folder, then live progress).
    var browserShowCatchWindow = true
    /// File types («zip», «apk»…) whose popup was answered with «Don't ask for … files»: they start straight away.
    var catchSkipTypes: [String] = []
    /// The folder last picked in the popup; it opens there next time while the folder exists.
    var catchLastFolder = ""
    /// The popup's «Start paused» switch, kept between popups.
    var catchStartPaused = false
    var browserCatchExtensions = "zip rar 7z dmg pkg iso exe msi apk ipa tar gz tgz bz2 xz torrent mp4 mkv mov avi mp3 flac wav pdf epub"
    var browserMinCatchSizeMB = 1
    var browserSkipHosts = ""
    /// Root opens magnet links and .torrent files, and its browser extension takes over downloads.
    var isDefaultDownloadManager = true
    var directConnections = 16
    var autoRetryAttempts = 2
    var quarantineDownloads = true

    // Presets & credentials (passwords live in the Keychain)
    var customPresets: [DownloadPreset] = []
    var credentials: [Credential] = []
    var lastUsedFileType: MediaFileType = .mp4
    var lastUsedVideoQuality: VideoQuality = .best
    var lastUsedAudioQuality: AudioQuality = .best

    var allPresets: [DownloadPreset] { DownloadPreset.builtIn + customPresets }

    /// True while the bandwidth schedule's window is active (handles windows that wrap past midnight).
    func isInBandwidthWindow(at date: Date, calendar: Calendar = .current) -> Bool {
        guard bandwidthScheduleEnabled, bandwidthScheduleStartHour != bandwidthScheduleEndHour else { return false }
        if bandwidthScheduleWeekdaysOnly, calendar.isDateInWeekend(date) { return false }
        let hour = calendar.component(.hour, from: date)
        let start = bandwidthScheduleStartHour, end = bandwidthScheduleEndHour
        return start < end ? (hour >= start && hour < end) : (hour >= start || hour < end)
    }

    /// Global cap right now in KB/s (0 = unlimited): the schedule's cap inside its window, else the normal limit.
    func effectiveSpeedLimitKBps(at date: Date = Date()) -> Int {
        guard isInBandwidthWindow(at: date) else { return speedLimitKBps }
        let scheduled = max(1, bandwidthScheduleLimitKBps)
        return speedLimitKBps > 0 ? min(speedLimitKBps, scheduled) : scheduled
    }

    /// Cap for one download: its own limit wins, else the global/scheduled one.
    func speedLimit(for options: DownloadOptions, at date: Date = Date()) -> Int {
        options.speedLimitKBps ?? effectiveSpeedLimitKBps(at: date)
    }
    var defaultPreset: DownloadPreset { allPresets.first { $0.id == defaultPresetID } ?? DownloadPreset.builtIn[0] }

    /// Preset for a quick download from `platform`: explicit per-platform choice, then smart audio, then the default.
    func preset(for platform: Platform) -> DownloadPreset {
        if let id = platformPresets[platform.rawValue], let preset = allPresets.first(where: { $0.id == id }) { return preset }
        if smartAudioForMusicPlatforms, platform.prefersAudio,
           let audio = allPresets.first(where: { $0.fileType.isAudio }) { return audio }
        return defaultPreset
    }
}

@Observable
final class AppSettings {
    private static let storageKey = "preferences.v1"

    var prefs: Preferences {
        didSet { if prefs != oldValue { persist() } }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.prefs = Self.load(from: defaults)
    }

    @ObservationIgnored private let defaults: UserDefaults

    func reset() { prefs = Preferences() }

    private func persist() {
        if let data = try? JSONEncoder().encode(prefs) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    /// Overlays stored values on top of the defaults so adding a field never wipes settings.
    static func load(from defaults: UserDefaults) -> Preferences {
        guard let data = defaults.data(forKey: storageKey),
              let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let baseData = try? JSONEncoder().encode(Preferences()),
              var merged = try? JSONSerialization.jsonObject(with: baseData) as? [String: Any]
        else { return Preferences() }
        merged.merge(stored) { _, new in new }
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              let prefs = try? JSONDecoder().decode(Preferences.self, from: mergedData)
        else { return Preferences() }
        return prefs
    }
}
