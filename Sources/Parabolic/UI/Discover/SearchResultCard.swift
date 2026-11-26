import SwiftUI

/// One search result: 16:9 artwork, two-line title, uploader and views.
/// Hover reveals glass Download / Options / Copy Link buttons; in select mode a click toggles selection.
struct SearchResultCard: View {
    var entry: PlaylistEntry
    var platform: Platform
    var isQueued: Bool
    var isSelecting: Bool
    var isSelected: Bool
    var onDownload: () -> Void
    var onOptions: () -> Void
    var onToggle: () -> Void

    @State private var hovering = false
    @State private var copied = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let cardRadius: CGFloat = 16
    private static let thumbRadius: CGFloat = 11
    private static let inset: CGFloat = 6

    private var metaLine: String {
        [entry.uploader, DiscoverFormat.views(entry.viewCount)].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.space2) {
            artwork
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 5) {
                    PlatformGlyph(platform: platform, size: 11, style: .monochrome)
                        .foregroundStyle(.tertiary)
                    Text(metaLine.isEmpty ? platform.title : metaLine)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(Self.inset)
        .padding(.bottom, 4)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Self.cardRadius)
                .fill(.primary.opacity(isSelected ? 0.08 : (hovering ? 0.05 : 0)))
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: Self.cardRadius).strokeBorder(Color.parabolicAccent, lineWidth: 2)
            }
        }
        .contentShape(.rect(cornerRadius: Self.cardRadius))
        .onTapGesture { isSelecting ? onToggle() : onOptions() }
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : Tokens.quick, value: hovering)
        .animation(reduceMotion ? nil : Tokens.quick, value: isSelected)
        .contextMenu { menu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.title)
        .accessibilityValue([metaLine, Format.duration(entry.duration), isQueued ? "Queued" : nil, isSelected ? "Selected" : nil]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(isSelecting ? "Toggles selection" : "Opens download options")
        .accessibilityAction(named: "Download") { onDownload() }
        .accessibilityAction(named: "Options") { onOptions() }
        .accessibilityAction(named: "Copy Link") { DiscoverActions.copy(entry.url) }
    }

    private var artwork: some View {
        ZStack {
            // GeometryReader keeps the 16:9 box flexible; ThumbnailView itself wants a concrete size.
            GeometryReader { proxy in
                ThumbnailView(url: entry.thumbnailURL, size: proxy.size, cornerRadius: Self.thumbRadius, duration: entry.duration,
                              symbol: platform.prefersAudio ? "music.note" : "play.rectangle")
            }
            if hovering && !isSelecting {
                RoundedRectangle(cornerRadius: Self.thumbRadius)
                    .fill(.black.opacity(0.38))
                    .allowsHitTesting(false)
                    .transition(.opacity)
                hoverActions
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .overlay(alignment: .topLeading) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .medium))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.9),
                                     isSelected ? Color.parabolicAccent : Color.black.opacity(0.25))
                    .shadow(color: .black.opacity(0.3), radius: 2)
                    .padding(8)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .overlay(alignment: .topTrailing) {
            if isQueued {
                Label("Queued", systemImage: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .glassCapsule(tint: .green.opacity(0.35))
                    .padding(8)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
    }

    private var hoverActions: some View {
        GlassEffectContainer(spacing: Tokens.space2) {
            HStack(spacing: Tokens.space2) {
                Button(action: onDownload) {
                    Label(isQueued ? "Queued" : "Download", systemImage: isQueued ? "checkmark" : "arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.glassProminent)
                .help(isQueued ? "Already in your downloads. Click to download again." : "Download with the \(platform.title) preset")
                Button(action: onOptions) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.glass)
                .help("Options…")
                .accessibilityLabel("Options")
                Button {
                    DiscoverActions.copy(entry.url)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.4))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "link").font(.system(size: 12, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.glass)
                .help("Copy Link")
                .accessibilityLabel("Copy Link")
            }
        }
        .controlSize(.regular)
    }

    @ViewBuilder
    private var menu: some View {
        Button("Download", systemImage: "arrow.down", action: onDownload)
        Button("Options…", systemImage: "slider.horizontal.3", action: onOptions)
        Divider()
        Button("Copy Link", systemImage: "link") { DiscoverActions.copy(entry.url) }
        Button("Open in Browser", systemImage: "safari") { DiscoverActions.open(entry.url) }
        Divider()
        Button(isSelected ? "Deselect" : "Select", systemImage: "checkmark.circle", action: onToggle)
    }
}

/// Placeholder card with the same geometry as a result.
struct SearchSkeletonCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.space2) {
            SkeletonBlock(cornerRadius: 11).aspectRatio(16 / 9, contentMode: .fit)
            VStack(alignment: .leading, spacing: 6) {
                SkeletonBlock(cornerRadius: 4).frame(height: 12)
                SkeletonBlock(cornerRadius: 4).frame(height: 12).padding(.trailing, 60)
                SkeletonBlock(cornerRadius: 4).frame(width: 90, height: 10).padding(.top, 2)
            }
            .padding(.horizontal, 4)
        }
        .padding(6)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }
}
