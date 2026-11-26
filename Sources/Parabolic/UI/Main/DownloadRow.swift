import SwiftUI

/// One download in the main list. Fixed height, three single-line text rows beside a 16:9 thumbnail,
/// and a fixed trailing column that swaps live numbers for actions on hover.
struct DownloadRow: View {
    let item: DownloadItem
    let actions: DownloadActions
    var isSelected = false

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let thumbSize = CGSize(width: 104, height: 58.5)
    /// Fixed trailing column so hover buttons never reflow the row.
    private static let trailingWidth: CGFloat = 132

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            RowThumbnail(item: item, size: Self.thumbSize)

            VStack(alignment: .leading, spacing: 0) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(item.title)
                    .frame(height: 18, alignment: .leading)
                secondaryLine
                    .frame(height: 16, alignment: .leading)
                DownloadRowStatus(item: item)
                    .frame(height: 18, alignment: .leading)
                    .padding(.top, 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
                .frame(width: Self.trailingWidth, alignment: .trailing)
        }
        .padding(.vertical, 8)
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .glassEffect(isSelected ? .regular.tint(Color.accentColor.opacity(0.22)).interactive() : .regular.interactive(),
                     in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.75) : .white.opacity(isHovered ? 0.18 : 0.08),
                              lineWidth: isSelected ? 1 : 0.5)
        )
        .animation(.adaptive(reduceMotion, Tokens.quick), value: isSelected)
        .scaleEffect(isHovered && !reduceMotion ? 1.004 : 1)
        .shadow(color: .black.opacity(isHovered ? 0.18 : 0), radius: isHovered ? 14 : 0, y: isHovered ? 6 : 0)
        .contentShape(.rect)
        .onHover { hovering in
            withAnimation(.adaptive(reduceMotion, Tokens.quick)) { isHovered = hovering }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.title), \(item.platform.title), \(item.status.label)")
    }

    private var secondaryLine: some View {
        let size = item.status == .completed ? nil : item.sizeDescription
        let parts: [String]
        if item.engine == .media {
            parts = [item.meta.uploader, item.options.fileType.label, size].compactMap { $0 }.filter { !$0.isEmpty }
        } else {
            // Files and torrents: kind plus size (final size once finished, since there is no format to show).
            parts = [item.kindTitle, item.sizeDescription ?? item.meta.uploader].compactMap { $0 }.filter { !$0.isEmpty }
        }
        return Text(parts.joined(separator: " · "))
            .monospacedDigit()
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    /// Live numbers at rest; glass actions on hover.
    @ViewBuilder private var trailing: some View {
        ZStack(alignment: .trailing) {
            if isHovered {
                DownloadRowActions(item: item, actions: actions)
                    .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .trailing)))
            } else {
                RowTrailingInfo(item: item)
                    .transition(.opacity)
            }
        }
    }
}

/// 16:9 artwork with the platform badge in the corner and a quiet duration label.
struct RowThumbnail: View {
    let item: DownloadItem
    var size: CGSize

    var body: some View {
        ItemArtwork(item: item, size: size, cornerRadius: 8, showsDuration: true)
            .overlay(alignment: .bottomLeading) {
                if item.showsPlatformBadge {
                    PlatformBadge(platform: item.platform, size: 20)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .padding(4)
                }
            }
            .opacity(item.status == .completed && item.filePath != nil && !item.fileExists ? 0.55 : 1)
            .accessibilityHidden(true)
    }
}

/// Right-aligned numbers: speed and time left while active, finish time or state otherwise.
struct RowTrailingInfo: View {
    let item: DownloadItem

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            switch item.status {
            case .running:
                Text(Format.speed(item.speed)).foregroundStyle(.primary)
                Text(Format.eta(item.eta).isEmpty ? " " : Format.eta(item.eta))
            case .completed:
                Text(item.totalBytes.map { Format.bytes($0) } ?? " ").foregroundStyle(.primary)
                Text(item.finishedAt.map(LinkText.finished) ?? " ")
            case .scheduled:
                Text("Scheduled").foregroundStyle(.primary)
                Text(item.scheduledAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? " ")
            default:
                EmptyView()
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// The status line under the title: exactly one line tall in every state.
struct DownloadRowStatus: View {
    let item: DownloadItem

    var body: some View {
        switch item.status {
        case .running, .paused, .processing:
            active
        case .failed:
            Label {
                Text(item.errorMessage ?? "Download failed").lineLimit(1).truncationMode(.tail)
            } icon: {
                Image(systemName: "exclamationmark.circle.fill")
            }
            .font(.system(size: 11))
            .foregroundStyle(.red)
            .help(item.errorMessage ?? "Download failed")
        case .completed:
            completed
        case .queued, .scheduled, .stopped:
            Label(item.statusText, systemImage: item.status.symbol)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var active: some View {
        let processing = item.status == .processing
        return HStack(spacing: 10) {
            ProgressCapsule(progress: processing ? nil : item.progress, tint: Color.status(item.status), height: 4)
                .frame(maxWidth: 360)
            Group {
                if processing {
                    Text(item.statusText)
                } else if item.status == .paused {
                    Text("Paused · \(Format.percent(item.progress))")
                } else if item.progress != nil {
                    Text(Format.percent(item.progress)).fontWeight(.semibold).foregroundStyle(.primary)
                } else {
                    Text(item.statusText)
                }
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
        }
    }

    private var completed: some View {
        let missing = item.filePath != nil && !item.fileExists
        return Label {
            Text(missing ? "File moved or deleted" : "Completed")
        } icon: {
            Image(systemName: missing ? "questionmark.folder" : "checkmark.circle.fill")
                .foregroundStyle(missing ? Color.secondary : Color.status(.completed))
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// Artwork for an item; while there is none yet, a calm placeholder with the site's mark instead of a generic icon.
struct ItemArtwork: View {
    let item: DownloadItem
    var size: CGSize
    var cornerRadius: CGFloat
    var showsDuration = true

    var body: some View {
        if item.meta.thumbnailURL == nil, let symbol = item.engineSymbol {
            EngineArtworkTile(symbol: symbol, caption: item.engineCaption, size: size, cornerRadius: cornerRadius)
        } else if item.meta.thumbnailURL != nil {
            ThumbnailView(url: item.meta.thumbnailURL, size: size, cornerRadius: cornerRadius,
                          duration: showsDuration ? item.meta.duration : nil,
                          symbol: item.options.fileType.isAudio ? "waveform" : "play.rectangle")
        } else {
            ArtworkPlaceholder(platform: item.platform, isAudio: item.options.fileType.isAudio,
                               size: size, cornerRadius: cornerRadius)
        }
    }
}

struct ArtworkPlaceholder: View {
    let platform: Platform
    var isAudio = false
    var size: CGSize
    var cornerRadius: CGFloat

    var body: some View {
        let mark = min(size.width, size.height) * 0.3
        ZStack {
            LinearGradient(colors: [Color.primary.opacity(0.09), Color.primary.opacity(0.035)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if platform == .other {
                Image(systemName: isAudio ? "waveform" : "play.rectangle")
                    .font(.system(size: mark * 0.8, weight: .light))
                    .foregroundStyle(.tertiary)
            } else {
                PlatformGlyph(platform: platform, size: mark, style: .monochrome)
                    .foregroundStyle(.quaternary)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.primary.opacity(0.08)))
    }
}
