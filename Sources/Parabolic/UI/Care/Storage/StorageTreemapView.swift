import SwiftUI

/// One block in the space map.
struct StorageTile: Identifiable, Equatable {
    enum Style { case folder, package, file, symlink, smaller }

    let id: String
    let rect: CGRect
    let item: StorageItem?
    let style: Style
    /// 0 = child of the current folder, 1 = grandchild drawn inside its folder.
    let depth: Int
    let label: String
    let bytes: Int64
    /// Leaves room for a header strip because grandchildren are drawn inside.
    let hasChildren: Bool
}

/// Lays out the current folder (and, where there's room, each subfolder's contents) as a squarified treemap.
enum StorageTileLayout {
    static let maxTopTiles = 160
    static let maxNestedTiles = 36
    private static let headerHeight: CGFloat = 18

    static func tiles(for listing: StorageListing, in bounds: CGRect,
                      sublisting: (URL) -> StorageListing?) -> [StorageTile] {
        let total = max(listing.totalBytes, 1)
        // Anything smaller than a few pixels joins the "smaller items" block.
        let minimum = Int64(Double(total) * 12 / Double(max(bounds.width * bounds.height, 1)))
        let shown = listing.items.filter { $0.bytes > 0 && $0.bytes >= minimum }.prefix(maxTopTiles)
        let shownBytes = shown.reduce(Int64(0)) { $0 + $1.bytes }
        let smallerBytes = listing.totalBytes - shownBytes
        let smallerCount = listing.items.count - shown.count + listing.otherCount

        var values = shown.map { Double($0.bytes) }
        if smallerBytes > 0 { values.append(Double(smallerBytes)) }
        let rects = StorageTreemap.layout(values, in: bounds)

        var tiles: [StorageTile] = []
        for (item, rect) in zip(shown, rects) {
            let style = style(for: item)
            let nested = item.kind == .folder && rect.width > 96 && rect.height > 64 ? sublisting(item.url) : nil
            let hasChildren = nested.map { !$0.items.isEmpty } ?? false
            tiles.append(StorageTile(id: item.url.path, rect: rect, item: item, style: style, depth: 0,
                                     label: item.name, bytes: item.bytes, hasChildren: hasChildren))
            if let nested, hasChildren {
                let inner = CGRect(x: rect.minX + 3, y: rect.minY + headerHeight, width: rect.width - 6,
                                   height: rect.height - headerHeight - 3)
                tiles += nestedTiles(nested, in: inner, parentBytes: item.bytes)
            }
        }
        if smallerBytes > 0, let rect = rects.last {
            tiles.append(StorageTile(id: "smaller", rect: rect, item: nil, style: .smaller, depth: 0,
                                     label: "\(smallerCount.formatted()) smaller item\(smallerCount == 1 ? "" : "s")",
                                     bytes: smallerBytes, hasChildren: false))
        }
        return tiles
    }

    private static func nestedTiles(_ listing: StorageListing, in rect: CGRect, parentBytes: Int64) -> [StorageTile] {
        guard rect.width > 8, rect.height > 8 else { return [] }
        let shown = listing.items.filter { $0.bytes > 0 }.prefix(maxNestedTiles)
        let rest = max(0, parentBytes - shown.reduce(0) { $0 + $1.bytes })
        var values = shown.map { Double($0.bytes) }
        if rest > 0 { values.append(Double(rest)) }
        let rects = StorageTreemap.layout(values, in: rect)
        return zip(shown, rects).compactMap { item, rect in
            guard rect.width >= 3, rect.height >= 3 else { return nil }
            return StorageTile(id: item.url.path, rect: rect, item: item, style: style(for: item), depth: 1,
                               label: item.name, bytes: item.bytes, hasChildren: false)
        }
    }

    private static func style(for item: StorageItem) -> StorageTile.Style {
        switch item.kind {
        case .folder: .folder
        case .package: .package
        case .file: .file
        case .symlink: .symlink
        }
    }

    /// Deepest tile under a point.
    static func hit(_ point: CGPoint, in tiles: [StorageTile]) -> StorageTile? {
        tiles.last { $0.depth == 1 && $0.rect.contains(point) } ?? tiles.first { $0.depth == 0 && $0.rect.contains(point) }
    }
}

/// The space map: every block's area is its share of the folder. Click a folder to open it.
/// Drawing and hover are separate views so moving the pointer never re-lays out or redraws the map.
struct StorageTreemapView: View {
    let listing: StorageListing
    let model: StorageExplorerModel
    let actions: (StorageItem) -> StorageItemMenu

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size).insetBy(dx: 1, dy: 1)
            let tiles = StorageTileLayout.tiles(for: listing, in: bounds) { model.listing(for: $0) }
            ZStack(alignment: .topLeading) {
                StorageTreemapCanvas(tiles: tiles).equatable()
                StorageTreemapOverlay(tiles: tiles, listing: listing, model: model, actions: actions)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Space map of \(listing.folder.lastPathComponent)")
        .accessibilityValue(listing.items.prefix(3).map { "\($0.name) \(Format.bytes($0.bytes))" }.joined(separator: ", "))
        .accessibilityHint("The list next to the map has the same items and works with the keyboard.")
    }
}

/// Draws the tiles. Equatable so it only redraws when the layout changes.
private struct StorageTreemapCanvas: View, Equatable {
    let tiles: [StorageTile]
    @Environment(\.colorScheme) private var colorScheme

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.tiles == rhs.tiles }

    var body: some View {
        Canvas { context, _ in
            for tile in tiles { draw(tile, in: &context) }
        }
        .allowsHitTesting(false)
    }

    private func draw(_ tile: StorageTile, in context: inout GraphicsContext) {
        let inset: CGFloat = tile.depth == 0 ? 1 : 0.75
        let rect = tile.rect.insetBy(dx: inset, dy: inset)
        guard rect.width > 0.5, rect.height > 0.5 else { return }
        let limit = min(rect.width, rect.height) / 4
        let path = Path(roundedRect: rect, cornerRadius: min(tile.depth == 0 ? 6 : 3.5, limit), style: .continuous)
        context.fill(path, with: .color(fill(for: tile)))
        if tile.style == .smaller {
            context.stroke(path, with: .color(.primary.opacity(0.10)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        } else {
            // Soft top light for depth.
            context.fill(path, with: .linearGradient(
                Gradient(colors: [.white.opacity(colorScheme == .dark ? 0.10 : 0.16), .white.opacity(0)]),
                startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        }
        drawLabel(tile, rect: rect, in: &context)
    }

    private func fill(for tile: StorageTile) -> Color {
        let accent = Color.accentColor
        switch tile.style {
        case .folder: return tile.depth == 0 && tile.hasChildren ? accent.opacity(0.30) : accent.opacity(tile.depth == 0 ? 0.82 : 0.76)
        case .package: return accent.opacity(0.52)
        case .file: return Color.primary.opacity(tile.depth == 0 ? 0.20 : 0.24)
        case .symlink: return Color.primary.opacity(0.10)
        case .smaller: return Color.primary.opacity(0.06)
        }
    }

    private func drawLabel(_ tile: StorageTile, rect: CGRect, in context: inout GraphicsContext) {
        if tile.depth == 0 && tile.hasChildren {
            // Header strip above the nested blocks.
            guard rect.width > 50 else { return }
            let size = Text(Format.bytes(tile.bytes)).font(.system(size: 10, weight: .regular).monospacedDigit())
                .foregroundStyle(.secondary)
            let text = Text("\(tile.label)  \(size)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.primary)
            var clipped = context
            clipped.clip(to: Path(CGRect(x: rect.minX + 6, y: rect.minY, width: rect.width - 12, height: 17)))
            clipped.draw(text, at: CGPoint(x: rect.minX + 7, y: rect.minY + 8.5), anchor: .leading)
            return
        }
        let minWidth: CGFloat = tile.depth == 0 ? 54 : 64
        let minHeight: CGFloat = tile.depth == 0 ? 32 : 30
        guard rect.width >= minWidth, rect.height >= minHeight else { return }
        let onAccent = tile.style == .folder || tile.style == .package
        let primary: Color = onAccent ? .white : .primary
        let secondary: Color = onAccent ? .white.opacity(0.78) : .secondary
        var clipped = context
        clipped.clip(to: Path(rect.insetBy(dx: 5, dy: 3)))
        let nameSize: CGFloat = tile.depth == 0 && rect.width > 140 && rect.height > 70 ? 12 : 11
        clipped.draw(Text(tile.label).font(.system(size: nameSize, weight: .semibold)).foregroundStyle(primary),
                     at: CGPoint(x: rect.minX + 7, y: rect.minY + 6), anchor: .topLeading)
        clipped.draw(Text(Format.bytes(tile.bytes)).font(.system(size: 10).monospacedDigit()).foregroundStyle(secondary),
                     at: CGPoint(x: rect.minX + 7, y: rect.minY + 8 + nameSize + 2), anchor: .topLeading)
    }
}

/// Pointer tracking, click-to-open, the hover outline and the readout bubble.
private struct StorageTreemapOverlay: View {
    let tiles: [StorageTile]
    let listing: StorageListing
    let model: StorageExplorerModel
    let actions: (StorageItem) -> StorageItemMenu

    @State private var pointer: CGPoint?
    @State private var hoveredTile: StorageTile?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.clear
                highlight
                tooltip(in: proxy.size)
            }
            .contentShape(.rect)
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    pointer = point
                    let tile = StorageTileLayout.hit(point, in: tiles)
                    if tile?.id != hoveredTile?.id { hoveredTile = tile }
                    model.hover(tile?.depth == 0 ? tile?.item?.url : nil)
                case .ended:
                    pointer = nil
                    if hoveredTile != nil { hoveredTile = nil }
                    model.hover(nil)
                }
            }
            .gesture(SpatialTapGesture().onEnded { value in
                guard let item = StorageTileLayout.hit(value.location, in: tiles)?.item else { return }
                if item.canDrill { model.open(item.url) } else { model.select(item.url) }
            })
            .contextMenu {
                if let item = hoveredTile?.item { actions(item) }
            }
        }
    }

    @ViewBuilder private var highlight: some View {
        let selected = model.selection.flatMap { url in tiles.first { $0.item?.url == url } }
        let fromList = hoveredTile == nil ? model.hovered.flatMap { url in tiles.first { $0.depth == 0 && $0.item?.url == url } } : nil
        let hovered = hoveredTile ?? fromList
        if let selected {
            outline(selected, isSelection: true)
        }
        if let hovered, hovered.id != selected?.id {
            outline(hovered, isSelection: false)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered.id)
        }
    }

    private func outline(_ tile: StorageTile, isSelection: Bool) -> some View {
        let rect = tile.rect.insetBy(dx: 1, dy: 1)
        return RoundedRectangle(cornerRadius: tile.depth == 0 ? 6 : 3.5, style: .continuous)
            .fill(.white.opacity(isSelection ? 0 : 0.12))
            .strokeBorder(isSelection ? Color.primary.opacity(0.85) : .white.opacity(0.9), lineWidth: isSelection ? 2 : 1.5)
            .frame(width: max(0, rect.width), height: max(0, rect.height))
            .offset(x: rect.minX, y: rect.minY)
            .allowsHitTesting(false)
    }

    @ViewBuilder private func tooltip(in size: CGSize) -> some View {
        if let tile = hoveredTile, let pointer {
            let width: CGFloat = 240
            let x = min(max(8, pointer.x + 14), max(8, size.width - width - 8))
            let y = pointer.y + 74 > size.height ? pointer.y - 74 : pointer.y + 16
            VStack(alignment: .leading, spacing: 2) {
                Text(tile.label)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(Format.bytes(tile.bytes)) · \(StoragePercent.text(tile.bytes, of: listing.totalBytes)) of \(listing.folder.lastPathComponent)")
                    .font(.system(size: 11).monospacedDigit())
                Text(detail(for: tile))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: width, alignment: .leading)
            .fixedSize()
            .background(.regularMaterial, in: .rect(cornerRadius: 8, style: .continuous))
            .hairline(cornerRadius: 8)
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            .offset(x: x, y: max(4, y))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func detail(for tile: StorageTile) -> String {
        guard let item = tile.item else { return "Too small to show one by one" }
        switch item.kind {
        case .folder:
            if item.isSizing { return "Folder · measuring…" }
            return "Folder · \(item.fileCount.formatted()) file\(item.fileCount == 1 ? "" : "s") · click to open"
        case .package: return "Package · \(item.fileCount.formatted()) files"
        case .file: return "File"
        case .symlink: return "Symbolic link, not followed"
        }
    }
}
