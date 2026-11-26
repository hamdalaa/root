import SwiftUI

/// One past download: artwork, title, metadata, when, and whether the file is still there.
struct HistoryRow: View {
    let entry: HistoryEntry
    let actions: HistoryActions
    var isSelected = false

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let thumbSize = DownloadRow.thumbSize

    var body: some View {
        let onDisk = entry.fileExists
        HStack(spacing: 14) {
            ThumbnailView(url: entry.thumbnailURL, size: Self.thumbSize, cornerRadius: 8,
                          symbol: entry.placeholderSymbol)
                .opacity(onDisk ? 1 : 0.55)
                .overlay(alignment: .bottomLeading) {
                    PlatformBadge(platform: entry.platform, size: 20)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .padding(4)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .help(entry.title)
                Text(metadata)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(entry.date, format: .relative(presentation: .named))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    if !onDisk {
                        Chip(text: "File missing", symbol: "questionmark.folder")
                            .help(entry.filePath.map { "Not found at \($0)" } ?? "No file was recorded")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    CircleGlassButton(title: "Download Again", symbol: "arrow.down", tint: .parabolicAccent) {
                        actions.downloadAgain([entry])
                    }
                    // Missing files still get the button: it opens the folder the file was saved to.
                    CircleGlassButton(title: onDisk ? "Show in Finder" : "Show Folder in Finder",
                                      symbol: "magnifyingglass") { actions.reveal([entry]) }
                    CircleGlassButton(title: "Copy Link", symbol: "link") { actions.copyLinks([entry]) }
                }
            }
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            .frame(width: 96, alignment: .trailing)
        }
        .padding(.vertical, 8)
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : .primary.opacity(isHovered ? 0.05 : 0))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1))
        )
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .contentShape(.rect)
        .onHover { hovering in
            withAnimation(.adaptive(reduceMotion, Tokens.quick)) { isHovered = hovering }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(entry.title), \(entry.platform.title)")
    }

    private var metadata: String {
        [entry.uploader, entry.kindLabel, entry.fileSize.map { Format.bytes($0) }]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
