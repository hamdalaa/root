import SwiftUI

/// Before the first search: recent searches as glass chips, or a short explanation when there are none.
struct SearchInitialState: View {
    var recents: [RecentSearch]
    var onPick: (RecentSearch) -> Void
    var onRemove: (RecentSearch) -> Void
    var onClear: () -> Void

    var body: some View {
        if recents.isEmpty {
            DiscoverMessage(symbol: "magnifyingglass",
                            title: "Find something to download",
                            message: "Search YouTube, SoundCloud, Bilibili or Niconico, then download straight from the results. You can also paste a link here.")
        } else {
            VStack(alignment: .leading, spacing: Tokens.space3) {
                HStack {
                    Text("Recent searches")
                        .font(.system(size: 13, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("Clear", action: onClear)
                        .buttonStyle(.hover)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Clear recent searches")
                }
                GlassEffectContainer(spacing: Tokens.space2) {
                    ChipFlowLayout(spacing: Tokens.space2) {
                        ForEach(recents) { recent in
                            RecentChip(recent: recent, onPick: { onPick(recent) }, onRemove: { onRemove(recent) })
                        }
                    }
                }
            }
        }
    }
}

private struct RecentChip: View {
    var recent: RecentSearch
    var onPick: () -> Void
    var onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 6) {
                PlatformGlyph(platform: recent.source.platform, size: 12)
                Text(recent.query)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(hovering ? Color.primary.opacity(0.06) : nil).interactive(), in: .capsule)
        .onHover { hovering = $0 }
        .contextMenu { Button("Remove", systemImage: "xmark", action: onRemove) }
        .accessibilityLabel("Search \(recent.source.platform.title) for \(recent.query)")
    }
}

/// Shown above everything when the field holds a link instead of words.
struct OpenLinkCard: View {
    var link: String
    var onOpen: () -> Void

    private var platform: Platform { Platform.detect(url: link) }

    var body: some View {
        HStack(spacing: Tokens.space3) {
            PlatformBadge(platform: platform, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(platform == .other ? "Open this link" : "Open this \(platform.title) link")
                    .font(.system(size: 13, weight: .semibold))
                Text(link)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Tokens.space3)
            Button(action: onOpen) {
                Label("Open…", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .accessibilityHint("Opens the new download sheet for this link")
        }
        .padding(Tokens.space3)
        .padding(.leading, 2)
        .discoverPanel()
        .accessibilityElement(children: .combine)
    }
}

/// Floating glass bar for multi-select.
struct SearchSelectionBar: View {
    var count: Int
    var total: Int
    var onSelectAll: () -> Void
    var onCancel: () -> Void
    var onDownload: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: Tokens.space2) {
            HStack(spacing: Tokens.space2) {
                Text(count == 0 ? "Select results to download" : "\(count) selected")
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .contentTransition(.numericText())
                    .padding(.leading, Tokens.space2)
                if count < total {
                    Button("Select All", action: onSelectAll)
                        .buttonStyle(.hover)
                        .font(.system(size: 12))
                }
                Spacer(minLength: Tokens.space4)
                Button("Cancel", action: onCancel)
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button(action: onDownload) {
                    Label(count == 0 ? "Download selected" : "Download \(count) selected", systemImage: "arrow.down")
                        .monospacedDigit()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(count == 0)
            }
            .padding(Tokens.space2)
            .padding(.leading, Tokens.space1)
            .glassPanel(cornerRadius: 22)
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.primary.opacity(0.08)))
        }
        .controlSize(.large)
        .frame(maxWidth: 620)
        .padding(.horizontal, Tokens.space5)
        .padding(.bottom, Tokens.space4)
    }
}

/// Left-aligned wrapping layout for chips.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let isFirst = rows[rows.count - 1].indices.isEmpty
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += isFirst ? size.width : size.width + spacing
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
