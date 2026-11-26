import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Pulls download links out of anything dropped on the window: web URLs, magnet links, plain text,
/// text files and .torrent files.
@MainActor
enum DropIntake {
    static let types: [UTType] = [.fileURL, .url, .plainText, .text]

    /// Text files larger than this are ignored (a link list is never this big).
    private static let maxTextFileBytes = 4 * 1024 * 1024

    struct Result {
        /// Local .torrent files, started straight away.
        var torrentFiles: [String] = []
        /// Web and magnet links, routed to the add sheet or the import list.
        var links: [String] = []
        var isEmpty: Bool { torrentFiles.isEmpty && links.isEmpty }
    }

    static func intake(from providers: [NSItemProvider]) async -> Result {
        var chunks: [String] = []
        var torrents: [String] = []
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self), let url = await loadURL(provider) {
                if url.isFileURL, url.pathExtension.lowercased() == "torrent" {
                    torrents.append(url.path)
                } else if let text = url.isFileURL ? readTextFile(url) : url.absoluteString {
                    chunks.append(text)
                }
            } else if provider.canLoadObject(ofClass: String.self), let text = await loadString(provider) {
                chunks.append(text)
            }
        }
        var seen = Set<String>()
        return Result(torrentFiles: torrents.filter { seen.insert($0).inserted },
                      links: LinkScanner.allLinks(in: chunks.joined(separator: "\n")))
    }

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    private static func loadString(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { text, _ in continuation.resume(returning: text) }
        }
    }

    /// Reads .txt (and other plain-text) files; anything else is not a link list.
    private static func readTextFile(_ url: URL) -> String? {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .text) else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxTextFileBytes else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// Highlighted glass overlay shown while something is dragged over the window.
struct DropOverlay: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Tokens.radiusWindowCard, style: .continuous)
                .fill(Color.parabolicAccent.opacity(0.06))
            RoundedRectangle(cornerRadius: Tokens.radiusWindowCard, style: .continuous)
                .strokeBorder(Color.parabolicAccent.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))

            VStack(spacing: Tokens.space3) {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Color.parabolicAccent)
                Text("Drop to download")
                    .font(.system(size: 17, weight: .semibold))
                Text("Links, magnet links and .torrent files. One link opens the download sheet; several open the import list.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Tokens.space6)
            .padding(.vertical, Tokens.space5)
            .glassPanel(cornerRadius: Tokens.radiusWindowCard, tint: Color.parabolicAccent.opacity(0.12))
        }
        .padding(Tokens.space3)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}
