import Foundation
import Observation

/// A followed channel / playlist. New uploads are downloaded automatically with its preset.
struct Subscription: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var url: String
    var title: String
    var uploader: String?
    var thumbnailURL: String?
    var presetID: UUID?
    var isEnabled = true
    /// When off, new uploads are only listed (badge) rather than downloaded.
    var autoDownload = true
    /// Entry URLs already seen; anything else is "new".
    var knownURLs: [String] = []
    var lastChecked: Date?
    var lastError: String?
    var newCount = 0

    var platform: Platform { Platform.detect(url: url) }
}

@MainActor
@Observable
final class SubscriptionStore {
    private(set) var subscriptions: [Subscription] = []
    private(set) var checkingIDs: Set<UUID> = []
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let tools: ToolStore
    @ObservationIgnored private weak var manager: DownloadManager?
    @ObservationIgnored private var timer: Timer?

    /// How many entries to look at on each check (newest first on most sites).
    static let scanDepth = 30

    init(settings: AppSettings, tools: ToolStore, manager: DownloadManager,
         fileURL: URL = ToolStore.supportDirectory.appendingPathComponent("subscriptions.json")) {
        self.settings = settings
        self.tools = tools
        self.manager = manager
        self.fileURL = fileURL
        subscriptions = LossyDecoding.decodeArray(Subscription.self, from: fileURL, decoder: .iso)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDue() }
        }
    }

    var isChecking: Bool { !checkingIDs.isEmpty }

    /// Follows a channel/playlist. Existing uploads are marked seen; only future ones download.
    /// - Parameter downloadLatest: also queue this many of the current newest entries now.
    func add(url: String, presetID: UUID?, autoDownload: Bool, downloadLatest: Int = 0) async throws {
        guard let normalized = Discovery.normalizeURL(url).map(Self.channelFeedURL) else { throw DiscoveryError.invalidURL }
        guard !subscriptions.contains(where: { $0.url == normalized }) else { return }
        let info = try await Discovery.discover(url: normalized, prefs: settings.prefs, tools: tools.paths, credential: nil)
        guard info.isPlaylist else {
            throw DiscoveryError.failed("That link is a single video. Follow a channel, playlist or profile instead.")
        }
        var sub = Subscription(url: normalized, title: info.meta.title, uploader: info.meta.uploader,
                               thumbnailURL: info.meta.thumbnailURL ?? info.entries.first?.thumbnailURL,
                               presetID: presetID, autoDownload: autoDownload)
        let latest = Array(info.entries.prefix(Self.scanDepth))
        sub.knownURLs = latest.map(\.url)
        sub.lastChecked = Date()
        subscriptions.insert(sub, at: 0)
        save()
        for entry in latest.prefix(max(0, downloadLatest)).reversed() { enqueue(entry, for: sub) }
    }

    /// YouTube channel roots list tabs (Videos/Shorts/Live), not uploads — follow the Videos tab.
    nonisolated static func channelFeedURL(_ url: String) -> String {
        guard Platform.detect(url: url) == .youtube, var components = URLComponents(string: url) else { return url }
        let parts = components.path.split(separator: "/")
        let isChannel = parts.first.map { $0.hasPrefix("@") || $0 == "channel" || $0 == "c" || $0 == "user" } ?? false
        let channelDepth = parts.first?.hasPrefix("@") == true ? 1 : 2
        guard isChannel, parts.count == channelDepth else { return url }
        components.path = "/" + parts.joined(separator: "/") + "/videos"
        return components.string ?? url
    }

    func remove(_ id: UUID) {
        subscriptions.removeAll { $0.id == id }
        save()
    }

    func update(_ sub: Subscription) {
        guard let index = subscriptions.firstIndex(where: { $0.id == sub.id }) else { return }
        subscriptions[index] = sub
        save()
    }

    func clearNewBadge(_ id: UUID) {
        guard let index = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        subscriptions[index].newCount = 0
        save()
    }

    func checkAll() {
        for sub in subscriptions where sub.isEnabled { Task { await check(sub.id) } }
    }

    private func checkDue() {
        guard settings.prefs.subscriptionsEnabled, tools.isReady else { return }
        let interval = TimeInterval(max(15, settings.prefs.subscriptionCheckMinutes) * 60)
        for sub in subscriptions where sub.isEnabled && !checkingIDs.contains(sub.id) {
            if (sub.lastChecked.map { Date().timeIntervalSince($0) >= interval }) ?? true {
                Task { await check(sub.id) }
            }
        }
    }

    /// Looks for uploads not seen before and queues (or flags) them.
    func check(_ id: UUID) async {
        guard let sub = subscriptions.first(where: { $0.id == id }), !checkingIDs.contains(id) else { return }
        checkingIDs.insert(id)
        defer { checkingIDs.remove(id) }
        var prefs = settings.prefs
        prefs.extraDiscoveryArguments += " --playlist-end \(Self.scanDepth)"
        do {
            let info = try await Discovery.discover(url: sub.url, prefs: prefs, tools: tools.paths, credential: nil)
            guard var current = subscriptions.first(where: { $0.id == id }) else { return }
            let known = Set(current.knownURLs)
            let fresh = info.entries.filter { !known.contains($0.url) }
            if current.autoDownload {
                for entry in fresh.reversed() { enqueue(entry, for: current) }
            } else {
                current.newCount += fresh.count
            }
            // Keep the seen list bounded but larger than the scan depth.
            current.knownURLs = Array((fresh.map(\.url) + current.knownURLs).prefix(Self.scanDepth * 10))
            current.lastChecked = Date()
            current.lastError = nil
            if current.thumbnailURL == nil { current.thumbnailURL = info.entries.first?.thumbnailURL }
            update(current)
        } catch {
            guard var current = subscriptions.first(where: { $0.id == id }) else { return }
            current.lastChecked = Date()
            current.lastError = error.localizedDescription
            update(current)
        }
    }

    private func enqueue(_ entry: PlaylistEntry, for sub: Subscription) {
        guard let manager else { return }
        let prefs = settings.prefs
        let preset = sub.presetID.flatMap { id in prefs.allPresets.first { $0.id == id } } ?? prefs.preset(for: sub.platform)
        var options = DownloadOptions(url: entry.url, saveFolder: prefs.downloadFolder)
        preset.apply(to: &options)
        let meta = MediaMeta(title: entry.title, uploader: entry.uploader ?? sub.uploader ?? sub.title, duration: entry.duration,
                             thumbnailURL: entry.thumbnailURL, webpageURL: entry.url)
        manager.enqueue(options: options, meta: meta)
    }

    private func save() {
        if let data = try? JSONEncoder.iso.encode(subscriptions) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
