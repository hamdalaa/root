import SwiftUI

/// The popup's primary row: artwork with the site's badge, the full file name, size + time estimate, chips.
struct CatchHeader: View {
    @Bindable var model: CatchModel
    let isEditable: Bool
    let eta: Int?

    static let artworkSide: CGFloat = 72

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            artwork
                .overlay(alignment: .bottomTrailing) {
                    CatchSiteBadge(platform: model.platform, host: model.pageHost ?? model.host)
                        .offset(x: 5, y: 5)
                }
            VStack(alignment: .leading, spacing: 5) {
                name
                HStack(spacing: 6) {
                    if model.isProbing && model.size == nil && !model.isMediaPage {
                        ProgressView().controlSize(.mini)
                    }
                    Text(subtitle)
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                chips
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if model.isMediaPage {
            ThumbnailView(url: model.thumbnailURL, size: Tokens.rowThumb, cornerRadius: Tokens.radiusThumb,
                          duration: model.duration, symbol: model.category == .music ? "waveform" : "play.rectangle")
        } else {
            EngineArtworkTile(symbol: model.isTorrent ? FileArtwork.torrentSymbol : FileArtwork.symbol(forFilename: model.filename),
                              caption: FileArtwork.extensionLabel(forFilename: model.filename),
                              size: CGSize(width: Self.artworkSide, height: Self.artworkSide), cornerRadius: Tokens.radiusRow)
        }
    }

    @ViewBuilder
    private var name: some View {
        if isEditable {
            TextField("File name", text: $model.filename, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1...2)
                .accessibilityLabel("File name")
        } else {
            Text(model.filename)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    /// "6 MB · about 2 sec · github.com"; "Unknown size" rather than a guess.
    private var subtitle: String {
        var parts: [String] = []
        if model.isMediaPage {
            if let preset = model.preset { parts.append(preset.name) }
            if let duration = Format.duration(model.duration) { parts.append(duration) }
            if model.isProbing { parts.append("Reading the page…") }
        } else if let size = model.size {
            parts.append(Format.bytes(size))
            if let eta { parts.append(CatchDetails.etaText(eta)) }
        } else {
            parts.append(model.isProbing ? "Checking size…" : "Unknown size")
        }
        if !model.host.isEmpty { parts.append(model.host) }
        return parts.joined(separator: " · ")
    }

    private var chips: some View {
        HStack(spacing: 6) {
            Chip(text: model.category.rawValue, symbol: model.category.symbol)
                .help("Sorted into the \(model.category.rawValue) folder when sorting by type is on")
            if model.resumable == true {
                Chip(text: "Resumable", symbol: "arrow.clockwise", tint: .green)
                    .help("A pause or dropped connection picks up where it stopped")
            }
        }
        .fixedSize()
    }
}

/// The source site's mark on the artwork: Root's platform glyph, else the site's own favicon.
struct CatchSiteBadge: View {
    let platform: Platform
    let host: String
    static let side: CGFloat = 24

    var body: some View {
        if platform != .other {
            PlatformBadge(platform: platform, size: Self.side)
        } else if !host.isEmpty, let url = URL(string: "https://\(host)/favicon.ico") {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().interpolation(.high).scaledToFit()
                        .padding(4)
                        .frame(width: Self.side, height: Self.side)
                        .background(.background.opacity(0.9), in: .rect(cornerRadius: Self.side * 0.28))
                        .overlay(RoundedRectangle(cornerRadius: Self.side * 0.28).strokeBorder(.primary.opacity(0.08)))
                }
            }
            .frame(width: Self.side, height: Self.side)
            .accessibilityHidden(true)
        }
    }
}
