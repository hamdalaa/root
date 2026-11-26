import AppKit
import SwiftUI

/// Large 16:9 cards in an adaptive grid. Click selects, ⌘-click toggles, double-click opens.
struct DownloadsGrid: View {
    let items: [DownloadItem]
    let actions: DownloadActions
    var onQuickLook: (URL) -> Void
    /// Scrolls away with the cards, like a large title.
    var header: AnyView? = nil

    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 18, alignment: .top)]

    var body: some View {
        ScrollView {
            header
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 22) {
                ForEach(items) { item in
                    DownloadGridCard(item: item, actions: actions, isSelected: appState.selectedItemIDs.contains(item.id))
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94)))
                        .onTapGesture(count: 2) { actions.open([item]) }
                        .onTapGesture { select(item) }
                        .contextMenu {
                            DownloadContextMenu(items: menuItems(for: item), actions: actions, onQuickLook: onQuickLook)
                        }
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .animation(.adaptive(reduceMotion), value: items.map(\.id))
        }
        .contentMargins(.bottom, 80, for: .scrollContent)
        .background {
            Color.clear.contentShape(.rect).onTapGesture { appState.selectedItemIDs = [] }
        }
        .onDeleteCommand { actions.remove(actions.items(appState.selectedItemIDs)) }
        .accessibilityLabel("Downloads")
    }

    private func select(_ item: DownloadItem) { appState.clickSelect(item.id, in: items.map(\.id)) }

    /// Right-click acts on the whole selection when the card is part of it, else just this card.
    private func menuItems(for item: DownloadItem) -> [DownloadItem] {
        appState.selectedItemIDs.contains(item.id) ? actions.items(appState.selectedItemIDs) : [item]
    }
}

/// One grid card: artwork with badge, progress on the artwork's lower edge, title and a status line.
struct DownloadGridCard: View {
    let item: DownloadItem
    let actions: DownloadActions
    var isSelected: Bool

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let radius: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            artwork
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2, reservesSpace: true)
                    .help(item.title)
                statusLine
            }
            .padding(.horizontal, 4)
        }
        .padding(8)
        .glassEffect(isSelected ? .regular.tint(Color.accentColor.opacity(0.22)).interactive() : .regular.interactive(),
                     in: .rect(cornerRadius: Self.radius + 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.radius + 8, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.75) : .white.opacity(0.08), lineWidth: isSelected ? 1 : 0.5)
        )
        .contentShape(.rect)
        .onHover { hovering in
            withAnimation(.adaptive(reduceMotion, Tokens.quick)) { isHovered = hovering }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(item.platform.title), \(item.status.label)")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var artwork: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    ItemArtwork(item: item, size: proxy.size, cornerRadius: Self.radius,
                                showsDuration: !item.status.isActive)
                }
            }
            .overlay(alignment: .topLeading) {
                if item.showsPlatformBadge {
                    PlatformBadge(platform: item.platform, size: 24)
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        .padding(8)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isHovered {
                    DownloadRowActions(item: item, actions: actions)
                        .padding(8)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) { progressStrip }
            .clipShape(.rect(cornerRadius: Self.radius, style: .continuous))
            .shadow(color: .black.opacity(isHovered ? 0.22 : 0.1), radius: isHovered ? 12 : 4, y: isHovered ? 6 : 2)
            .scaleEffect(isHovered && !reduceMotion ? 1.015 : 1)
    }

    @ViewBuilder private var progressStrip: some View {
        if item.status.isActive {
            HStack(spacing: 8) {
                ProgressCapsule(progress: item.status == .processing ? nil : item.progress, tint: .white, height: 4)
                Text(item.status == .processing ? "Processing" : Format.percent(item.progress))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
        }
    }

    private var statusLine: some View {
        HStack(spacing: 5) {
            if let symbol = item.engineSymbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                PlatformGlyph(platform: item.platform, size: 11, style: .monochrome)
                    .foregroundStyle(.secondary)
            }
            Text(statusText)
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: 0)
            if item.status == .failed {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            } else if item.status == .completed {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.status(.completed))
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private var statusText: String {
        let platform = item.kindTitle
        switch item.status {
        case .running:
            return [platform, Format.speed(item.speed), Format.eta(item.eta)].filter { !$0.isEmpty }.joined(separator: " · ")
        case .completed:
            return [platform, item.totalBytes.map { Format.bytes($0) }].compactMap { $0 }.joined(separator: " · ")
        case .failed:
            return "\(platform) · Failed"
        default:
            return "\(platform) · \(item.statusText)"
        }
    }
}
