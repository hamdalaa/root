import Foundation
import Observation

/// State for one caught download: confirm → downloading → finished.
@MainActor
@Observable
final class CatchModel: Identifiable {
    enum Stage: Equatable { case confirm, downloading(UUID), cancelled }

    let id = UUID()
    let source: BrowserItem
    var filename: String
    var folder: String
    var size: Int64?
    var contentType: String?
    var resumable: Bool?
    var isProbing = true
    var stage: Stage = .confirm
    /// «Don't ask for ZIP files»: remembered on «Download» / «Download Later», never on Cancel.
    var skipThisType = false
    /// Add it to the list without starting; kept between popups.
    var startPaused = false
    /// Quality/format for media pages (Root's presets).
    var preset: DownloadPreset?
    /// Poster frame for media pages, from yt-dlp.
    var thumbnailURL: String?
    var duration: Double?

    init(source: BrowserItem, folder: String, startPaused: Bool = false, preset: DownloadPreset? = nil) {
        self.source = source
        self.folder = folder
        self.startPaused = startPaused
        self.size = source.size
        self.contentType = source.mime
        let fallback = URL(string: source.url)?.lastPathComponent ?? "Download"
        self.filename = (source.filename?.isEmpty == false ? source.filename! : fallback)
        if CatchFlow.isMediaPage(source.url) {
            self.preset = preset
            self.filename = source.title.flatMap { $0.isEmpty ? nil : $0 } ?? URL(string: source.url)?.host ?? source.url
        }
    }

    var host: String { URL(string: source.url)?.host ?? "" }
    var isTorrent: Bool { EngineRouter.engine(for: source.url) == .torrent }
    var isMediaPage: Bool { CatchFlow.isMediaPage(source.url) }
    var platform: Platform { Platform.detect(url: source.pageURL ?? source.url) }

    /// The page the download was started from, when the browser said.
    var pageTitle: String? { source.title.flatMap { $0.isEmpty || isMediaPage ? nil : $0 } }
    var pageHost: String? { source.pageURL.flatMap { URL(string: $0)?.host } }

    /// The caught file's type («zip»), which the "don't ask" choice applies to. Empty for media pages.
    var fileType: String { isMediaPage ? "" : CatchFlow.fileType(of: source) }

    /// Picked from the file type; follows the name while it's edited.
    var category: FileCategory {
        if isMediaPage { return (preset?.fileType.isAudio ?? false) ? .music : .video }
        return FileCategory.of(filename: filename, engine: isTorrent ? .torrent : .direct, fileType: .originalVideo)
    }

    func request(paused: Bool) -> CatchRequest {
        CatchRequest(url: source.url, filename: filename, headers: source.headers, folder: folder, size: size,
                     startPaused: paused, preset: isMediaPage ? preset : nil)
    }

    /// Keeps the folder and «Start paused» for the next popup, and the "don't ask" choice when it's ticked.
    func remember(in prefs: inout Preferences) {
        CatchFlow.remember(folder: folder, skipType: skipThisType ? fileType : nil, in: &prefs)
        if prefs.catchStartPaused != startPaused { prefs.catchStartPaused = startPaused }
    }

    /// Files: asks the server (with the browser's cookies) for the real name, size, type and resume support.
    /// Media pages: asks yt-dlp for the title and poster frame.
    func probe(prefs: Preferences, tools: ToolPaths) async {
        defer { isProbing = false }
        if isTorrent { return }
        if isMediaPage {
            guard let info = try? await Discovery.discover(url: source.url, prefs: prefs, tools: tools, credential: nil,
                                                           singleVideo: true) else { return }
            if !info.meta.title.isEmpty { filename = info.meta.title }
            thumbnailURL = info.meta.thumbnailURL
            duration = info.meta.duration
            return
        }
        guard let info = try? await DirectProbe.probe(source.url, headers: source.headers ?? [:]),
              let file = info.directFile else { return }
        if source.filename?.isEmpty ?? true { filename = file.filename }
        if size == nil { size = file.size }
        if contentType == nil { contentType = file.contentType }
        resumable = file.resumable
    }
}
