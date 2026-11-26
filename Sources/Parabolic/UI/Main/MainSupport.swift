import AppKit
import SwiftUI

// MARK: - Filtering

@MainActor
extension SidebarItem {
    /// The filters that show download rows (History has its own view).
    static let downloadFilters: [SidebarItem] = [.all, .downloading, .queued, .completed, .failed]
    /// The Mac Care tools, in sidebar order.
    static let careTools: [SidebarItem] = [.memory, .storage, .cleanup, .uninstaller, .loginItems, .forceQuit]

    func includes(_ item: DownloadItem) -> Bool {
        switch self {
        case .platform(let p): item.platform == p
        case .all, .history, .search, .subscriptions, .statistics, .speedTest: true
        case .memory, .storage, .cleanup, .uninstaller, .loginItems, .forceQuit: true
        case .downloading: item.status.isActive
        case .queued: item.status == .queued || item.status == .scheduled
        case .completed: item.status == .completed
        case .failed: item.status == .failed || item.status == .stopped
        }
    }
}

extension DownloadManager {
    func count(for filter: SidebarItem) -> Int {
        switch filter {
        case .all: items.count
        case .downloading: activeItems.count
        case .queued: queuedItems.count
        case .completed: completedItems.count
        case .failed: failedItems.count
        case .platform(let p): items.filter { $0.platform == p }.count
        case .history, .search, .subscriptions, .statistics, .speedTest: 0
        case .memory, .storage, .cleanup, .uninstaller, .loginItems, .forceQuit: 0
        }
    }

    /// Items for a set of ids, in list order.
    func items(_ ids: Set<UUID>) -> [DownloadItem] {
        items.filter { ids.contains($0.id) }
    }
}

extension SidebarItem {
    var platform: Platform? {
        if case .platform(let p) = self { return p }
        return nil
    }
}

extension DownloadItem {
    /// The page the media came from, used for "Copy Link" / "Open Source Page".
    var sourceURL: String { meta.webpageURL ?? options.url }

    /// The finished file, only when it is completed and still on disk.
    var completedFileURL: URL? { status == .completed && fileExists ? fileURL : nil }

    func matches(search query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return [meta.title, meta.uploader ?? "", options.url, meta.webpageURL ?? ""]
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }

    /// "12.4 MB of 48 MB" while downloading, the final size otherwise.
    var sizeDescription: String? {
        if status.isActive, downloadedBytes > 0 {
            guard let totalBytes else { return Format.bytes(downloadedBytes) }
            return "\(Format.bytes(downloadedBytes)) of \(Format.bytes(totalBytes))"
        }
        return totalBytes.map { Format.bytes($0) }
    }
}

extension HistoryEntry {
    var fileExists: Bool { filePath.map { FileManager.default.fileExists(atPath: $0) } ?? false }
    var fileURL: URL? { fileExists ? filePath.map { URL(fileURLWithPath: $0) } : nil }

    func matches(search query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return [title, uploader ?? "", url].contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

@MainActor
enum LinkText {
    /// "youtube.com" from a full URL, without the www.
    static func host(of url: String) -> String {
        guard let host = URL(string: url)?.host() else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// First link in the text, or the text itself when it already looks like a bare link.
    static func link(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return LinkScanner.firstLink(in: trimmed) ?? Discovery.normalizeURL(trimmed)
    }

    static var clipboardLink: String? {
        NSPasteboard.general.string(forType: .string).flatMap { LinkScanner.firstLink(in: $0) }
    }

    static func copy(_ strings: [String]) {
        guard !strings.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(strings.joined(separator: "\n"), forType: .string)
    }

    static func finished(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "Today at \(time)" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday at \(time)" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

extension Animation {
    /// The given animation, or none when Reduce Motion is on.
    static func adaptive(_ reduceMotion: Bool, _ animation: Animation = Tokens.motion) -> Animation? {
        reduceMotion ? nil : animation
    }
}

// MARK: - Shared pieces

/// Neutral, barely-there backdrop: a faint vertical wash so glass above has depth without any tint.
struct AmbientBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Soft cool light behind the translucent window, so the Liquid Glass surfaces have depth to refract.
        let strength = colorScheme == .dark ? 0.16 : 0.10
        ZStack {
            RadialGradient(colors: [Color.accentColor.opacity(strength), .clear],
                           center: UnitPoint(x: 0.15, y: 0.05), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Color.cyan.opacity(strength * 0.7), .clear],
                           center: UnitPoint(x: 0.95, y: 0.35), startRadius: 0, endRadius: 460)
            RadialGradient(colors: [Color.teal.opacity(strength * 0.45), .clear],
                           center: UnitPoint(x: 0.4, y: 1.05), startRadius: 0, endRadius: 520)
        }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// How the downloads list is laid out. Persisted with @AppStorage.
enum DownloadsLayout: String, CaseIterable, Identifiable {
    case list, grid

    static let storageKey = "downloadsLayout"
    var id: String { rawValue }
    var title: String { self == .list ? "List" : "Grid" }
    var symbol: String { self == .list ? "list.bullet" : "square.grid.2x2" }
}

/// Brand glyph rendered to an image so it can appear inside AppKit-backed menus.
@MainActor
enum PlatformMenuIcon {
    private static var cache: [Platform: NSImage] = [:]

    static func image(_ platform: Platform) -> Image {
        if let cached = cache[platform] { return Image(nsImage: cached) }
        let renderer = ImageRenderer(content: PlatformGlyph(platform: platform, size: 14).padding(1))
        renderer.scale = 2
        guard let image = renderer.nsImage else { return Image(systemName: "globe") }
        image.isTemplate = false
        cache[platform] = image
        return Image(nsImage: image)
    }
}

/// Thin hairline border used on every content panel.
extension View {
    func hairline(cornerRadius: CGFloat) -> some View {
        overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.primary.opacity(0.08)))
    }
}

/// Small circular Liquid Glass icon button used for row hover actions.
struct CircleGlassButton: View {
    let title: String
    let symbol: String
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 15, height: 15)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.small)
        .foregroundStyle(tint ?? .primary)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// A keyboard shortcut rendered as a key cap followed by what it does.
struct ShortcutHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Text(keys)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.primary.opacity(0.07), in: .rect(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.08)))
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Status symbol on a dark disc, overlaid on artwork.
struct StatusGlyph: View {
    let status: DownloadStatus

    var body: some View {
        Image(systemName: status.symbol)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(glyphColor)
            .frame(width: 18, height: 18)
            .background(.black.opacity(0.58), in: .circle)
            .overlay(Circle().strokeBorder(.white.opacity(0.12)))
            .accessibilityLabel(status.label)
    }

    private var glyphColor: Color {
        switch status {
        case .queued, .scheduled, .stopped: .white.opacity(0.85)
        default: Color.status(status)
        }
    }
}
