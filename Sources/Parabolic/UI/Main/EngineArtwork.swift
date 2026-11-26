import SwiftUI
import UniformTypeIdentifiers

/// SF Symbol artwork for plain files and torrents, which have no thumbnail of their own.
enum FileArtwork {
    static let torrentSymbol = "point.3.connected.trianglepath.dotted"

    private static let archives: Set<String> = ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst"]
    private static let diskImages: Set<String> = ["dmg", "iso", "img"]
    private static let installers: Set<String> = ["pkg", "deb", "rpm"]
    private static let documents: Set<String> = ["pdf", "epub", "mobi"]
    private static let apps: Set<String> = ["exe", "msi", "apk", "ipa", "xapk", "appimage", "jar"]
    private static let videos: Set<String> = ["mp4", "mkv", "mov", "avi", "webm", "m4v"]
    private static let audio: Set<String> = ["mp3", "flac", "wav", "m4a", "ogg", "aac", "opus"]

    /// Symbol chosen by the file's extension; `doc` when nothing more specific fits.
    static func symbol(forFilename name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        if archives.contains(ext) { return "doc.zipper" }
        if diskImages.contains(ext) { return "externaldrive" }
        if installers.contains(ext) { return "shippingbox" }
        if documents.contains(ext) { return "doc.richtext" }
        if apps.contains(ext) { return "app.dashed" }
        if videos.contains(ext) { return "film" }
        if audio.contains(ext) { return "music.note" }
        return "doc"
    }

    /// Short uppercase extension ("ZIP") for the tile's caption, nil when there is none.
    static func extensionLabel(forFilename name: String) -> String? {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, ext.count <= 8 else { return nil }
        return ext.uppercased()
    }

    /// Whether the finished file can be played in the inspector.
    static func isPlayable(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audiovisualContent)
    }
}

extension DownloadItem {
    var engine: DownloadEngine { options.resolvedEngine }

    /// "File" / "Torrent" for aria2 items; the platform name for media.
    var kindTitle: String { engine == .media ? platform.title : engine.label }

    /// The name the file has (or will have) on disk, for picking its artwork.
    private var displayFilename: String {
        if let filePath { return (filePath as NSString).lastPathComponent }
        let name = options.filename.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? meta.title : name
    }

    /// Symbol artwork for files and torrents; nil for media, which uses the site's artwork.
    var engineSymbol: String? {
        switch engine {
        case .media: nil
        case .direct: FileArtwork.symbol(forFilename: displayFilename)
        case .torrent: FileArtwork.torrentSymbol
        }
    }

    /// Files from unknown hosts skip the corner badge; the symbol already says what they are.
    var showsPlatformBadge: Bool { engine == .media || platform != .other }

    var engineCaption: String? {
        engine == .direct ? FileArtwork.extensionLabel(forFilename: displayFilename) : nil
    }
}

/// Neutral frosted tile with a large symbol, used wherever a thumbnail would go.
struct EngineArtworkTile: View {
    var symbol: String
    var caption: String?
    var size: CGSize
    var cornerRadius: CGFloat

    private var side: CGFloat { min(size.width, size.height) }
    private var showsCaption: Bool { caption != nil && side >= 56 }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.primary.opacity(0.10), Color.primary.opacity(0.035)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            // Soft top highlight so the tile reads as glass rather than a flat fill.
            LinearGradient(colors: [Color.white.opacity(0.10), .clear], startPoint: .top, endPoint: .center)
            VStack(spacing: side * 0.06) {
                Image(systemName: symbol)
                    .font(.system(size: side * (showsCaption ? 0.34 : 0.4), weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                if showsCaption, let caption {
                    Text(caption)
                        .font(.system(size: max(9, side * 0.1), weight: .semibold, design: .rounded))
                        .tracking(0.6)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .background(.ultraThinMaterial)
        .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .accessibilityHidden(true)
    }
}

extension HistoryEntry {
    /// History doesn't record the engine, and plain-file downloads keep the default `.mp4` type,
    /// so the file's own extension decides: an .apk shows as "APK", not "MP4".
    private var plainFilename: String? {
        let name = filePath.map { ($0 as NSString).lastPathComponent } ?? title
        switch FileCategory.of(filename: name, engine: .direct, fileType: fileType) {
        case .documents, .archives, .apps, .images: return name
        case .video, .music, .torrents, .other: return nil
        }
    }

    /// An .apk, .pdf, .zip… rather than video or audio.
    var isPlainFile: Bool { plainFilename != nil }

    /// "APK" / "PDF" for plain files, the media format ("MP4") otherwise.
    var kindLabel: String {
        plainFilename.flatMap(FileArtwork.extensionLabel(forFilename:)) ?? fileType.label
    }

    /// Placeholder artwork when there is no thumbnail.
    var placeholderSymbol: String {
        if let plainFilename { return FileArtwork.symbol(forFilename: plainFilename) }
        return fileType.isAudio ? "waveform" : "play.rectangle"
    }
}
