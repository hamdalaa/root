import SwiftUI

/// Context-menu actions for explorer items.
struct StorageItemMenu: View {
    let items: [StorageItem]
    let onOpen: (URL) -> Void
    let onQuickLook: (URL) -> Void
    let onTrash: ([StorageItem]) -> Void

    var body: some View {
        if items.count == 1, let item = items.first {
            if item.canDrill {
                Button("Open") { onOpen(item.url) }
            }
            Button("Quick Look") { onQuickLook(item.url) }
        }
        Button("Reveal in Finder") { StorageFinder.reveal(items.map(\.url)) }
        Button(items.count == 1 ? "Copy Path" : "Copy Paths") { StorageFinder.copyPaths(items.map(\.url)) }
        Divider()
        if let reason = items.lazy.compactMap({ StorageSafety.protectionReason(for: $0.url) }).first {
            Button("Can’t Move to Trash: \(reason)") {}
                .disabled(true)
        } else {
            Button("Move to Trash…", role: .destructive) { onTrash(items) }
                .disabled(items.contains(where: \.isSizing))
        }
    }
}

/// Sorted children of the current folder with a bar showing each one's share.
struct StorageItemList: View {
    let listing: StorageListing
    let model: StorageExplorerModel
    let onQuickLook: (URL) -> Void
    let onTrash: ([StorageItem]) -> Void

    private var selection: Binding<URL?> {
        Binding(get: { model.selection }, set: { model.select($0) })
    }

    var body: some View {
        let total = listing.totalBytes
        List(selection: selection) {
            ForEach(listing.items) { item in
                StorageItemRow(item: item, total: total, isHighlighted: model.hovered == item.url)
                    .tag(item.url)
                    .onHover { hovering in
                        if hovering { model.hover(item.url) } else if model.hovered == item.url { model.hover(nil) }
                    }
            }
            if listing.otherCount > 0 {
                StorageTailRow(count: listing.otherCount, bytes: listing.otherBytes, total: total)
                    .selectionDisabled()
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: URL.self) { urls in
            let items = listing.items.filter { urls.contains($0.url) }
            if !items.isEmpty {
                StorageItemMenu(items: items, onOpen: model.open, onQuickLook: onQuickLook, onTrash: onTrash)
            }
        } primaryAction: { urls in
            guard urls.count == 1, let url = urls.first, let item = listing.items.first(where: { $0.url == url }) else { return }
            if item.canDrill { model.open(url) } else { onQuickLook(url) }
        }
        .onKeyPress(.space) {
            guard let url = model.selection else { return .ignored }
            onQuickLook(url)
            return .handled
        }
        .onKeyPress(.delete, phases: .down) { press in
            guard press.modifiers.contains(.command), let url = model.selection,
                  let item = listing.items.first(where: { $0.url == url }), StorageSafety.canTrash(url) else { return .ignored }
            onTrash([item])
            return .handled
        }
        .accessibilityLabel("Items in \(listing.folder.lastPathComponent), largest first")
    }
}

struct StorageItemRow: View {
    let item: StorageItem
    let total: Int64
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            StorageIcons.image(for: item.url)
                .resizable()
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.isSizing {
                        ProgressView().controlSize(.mini)
                    }
                    Spacer(minLength: 6)
                    Text(item.bytes > 0 ? Format.bytes(item.bytes) : (item.isSizing ? "…" : "Zero KB"))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(item.isSizing ? .secondary : .primary)
                        .contentTransition(.numericText())
                }
                HStack(spacing: 8) {
                    StorageShareBar(fraction: total > 0 ? Double(item.bytes) / Double(total) : 0,
                                    tint: item.kind == .folder || item.kind == .package ? Color.accentColor : Color.secondary)
                    Text(StoragePercent.text(item.bytes, of: total))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .opacity(item.canDrill ? 1 : 0)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 2)
        .background(RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(isHighlighted ? 0.05 : 0)).padding(-3))
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(item.canDrill ? "Double-click or press Return to open" : "Press Space for Quick Look")
    }

    private var kindText: String {
        switch item.kind {
        case .folder: "Folder"
        case .package: "Package"
        case .file: "File"
        case .symlink: "Symbolic link, not followed"
        }
    }

    private var help: String {
        var parts = [kindText, Format.bytes(item.bytes)]
        if item.kind == .folder || item.kind == .package { parts.append("\(item.fileCount.formatted()) files") }
        if item.unreadable > 0 { parts.append("\(item.unreadable) unreadable folder\(item.unreadable == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private var accessibilityValue: String {
        if item.isSizing { return "\(kindText), measuring, \(Format.bytes(item.bytes)) so far" }
        return "\(kindText), \(Format.bytes(item.bytes)), \(StoragePercent.text(item.bytes, of: total)) of this folder"
    }
}

/// The long tail, summed.
private struct StorageTailRow: View {
    let count: Int
    let bytes: Int64
    let total: Int64

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(.tertiary)
                .frame(width: 22, height: 22)
            Text("\(count.formatted()) smaller item\(count == 1 ? "" : "s")")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Text(Format.bytes(bytes))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// Thin proportional bar.
struct StorageShareBar: View {
    let fraction: Double
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(.primary.opacity(0.07))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(tint.opacity(0.85))
                        .frame(width: fraction > 0 ? max(3, proxy.size.width * min(1, fraction)) : 0)
                }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}
