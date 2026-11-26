import SwiftUI

/// Filterable, selectable list of playlist entries in a bounded card.
struct PlaylistEntriesCard: View {
    @Bindable var model: AddDownloadModel
    var info: MediaInfo

    private static let rowHeight: CGFloat = 61
    private static let maxListHeight: CGFloat = 300

    private var visible: [PlaylistEntry] { model.filteredEntries }
    private var isFiltering: Bool { !model.entryFilter.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Videos")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
            VStack(spacing: 0) {
                toolbar
                Divider().padding(.horizontal, 14)
                list
            }
            .glassPanel(cornerRadius: Tokens.radiusRow)
        }
    }

    private var toolbar: some View {
        HStack(spacing: Tokens.space2) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.tertiary).accessibilityHidden(true)
                TextField("Filter by title", text: $model.entryFilter)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Filter videos by title")
                if isFiltering {
                    Button {
                        model.entryFilter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(HoverButtonStyle(cornerRadius: 10, padding: 2))
                    .accessibilityLabel("Clear filter")
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.primary.opacity(0.05), in: .rect(cornerRadius: Tokens.radiusControl))

            Button(isFiltering ? "Select shown" : "Select all") {
                model.selectedEntryIDs.formUnion(visible.map(\.id))
            }
            .buttonStyle(.hover)
            .accessibilityLabel(isFiltering ? "Select all shown videos" : "Select all videos")
            Button("None") {
                model.selectedEntryIDs.subtract(visible.map(\.id))
            }
            .buttonStyle(.hover)
            .accessibilityLabel(isFiltering ? "Deselect shown videos" : "Deselect all videos")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var list: some View {
        if visible.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 20, weight: .light)).foregroundStyle(.tertiary)
                Text("No videos match “\(model.entryFilter)”.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Tokens.space5)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visible) { entry in
                        PlaylistEntryRow(entry: entry, isSelected: model.selectedEntryIDs.contains(entry.id)) {
                            if model.selectedEntryIDs.contains(entry.id) {
                                model.selectedEntryIDs.remove(entry.id)
                            } else {
                                model.selectedEntryIDs.insert(entry.id)
                            }
                        }
                    }
                }
                .padding(6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(CGFloat(visible.count) * Self.rowHeight + 12, Self.maxListHeight))
        }
    }
}

/// One selectable entry: checkbox, small thumbnail, index, title, duration.
struct PlaylistEntryRow: View {
    var entry: PlaylistEntry
    var isSelected: Bool
    var onToggle: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: Tokens.space3) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? Color.parabolicAccent : Color.secondary.opacity(0.7))
                    .contentTransition(.symbolEffect(.replace))
                ThumbnailView(url: entry.thumbnailURL, size: CGSize(width: 80, height: 45), cornerRadius: 6)
                    .opacity(isSelected ? 1 : 0.55)
                Text("\(entry.index)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 22, alignment: .trailing)
                Text(entry.title)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let duration = Format.duration(entry.duration) {
                    Text(duration)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(height: 57)
            .contentShape(.rect)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.primary.opacity(hovering ? 0.06 : 0))
            )
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Tokens.quick, value: hovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.index). \(entry.title)")
        .accessibilityValue([isSelected ? "Selected" : "Not selected", Format.duration(entry.duration)].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Toggles whether this video is downloaded")
    }
}
