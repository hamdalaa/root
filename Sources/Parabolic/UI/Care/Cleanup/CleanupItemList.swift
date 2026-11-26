import AppKit
import SwiftUI

/// The items inside an expanded category, largest first.
struct CleanupItemList: View {
    @Bindable var store: CleanupStore
    let result: CleanupCategoryResult
    @State private var showsAll = false

    private static let pageSize = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if result.category == .projectArtifacts { idlePicker }
            if result.items.isEmpty {
                Text("No project idle that long has build folders over 1 MB.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                    .padding(.bottom, 4)
            }
            let visible = showsAll ? result.items : Array(result.items.prefix(Self.pageSize))
            LazyVStack(spacing: 0) {
                ForEach(visible) { item in
                    CleanupItemRow(store: store, item: item)
                }
            }
            if result.items.count > Self.pageSize {
                Button(showsAll ? "Show fewer" : "Show all \(result.items.count.formatted())") { showsAll.toggle() }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .padding(.leading, 34)
                    .padding(.top, 4)
            }
        }
        .padding(.top, 2)
    }

    private var idlePicker: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar")
                .foregroundStyle(.secondary)
            Text("Only projects untouched for")
                .foregroundStyle(.secondary)
            Picker("Idle for", selection: Binding(
                get: { store.projectIdleDays },
                set: { days in if days != store.projectIdleDays { store.setProjectIdleDays(days) } }
            )) {
                ForEach(CleanupStore.idleDayChoices, id: \.self) { days in
                    Text(Self.idleLabel(days)).tag(days)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityLabel("Only projects untouched for")
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(.vertical, 6)
        .padding(.leading, 8)
    }

    static func idleLabel(_ days: Int) -> String {
        switch days {
        case 7: "1 week"
        case 14: "2 weeks"
        case 30: "1 month"
        case 60: "2 months"
        case 90: "3 months"
        case 180: "6 months"
        case 365: "1 year"
        default: "\(days) days"
        }
    }
}

private struct CleanupItemRow: View {
    @Bindable var store: CleanupStore
    let item: CleanupItem
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            CleanupCheckbox(mark: store.isSelected(item) ? .on : .off, label: item.name) {
                store.setSelected(item, !store.isSelected(item))
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let detail = item.detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let owner = item.inUseBy {
                        CleanupBadge(text: "In use by \(owner)", symbol: "app.badge", tint: .yellow)
                            .help("\(owner) is open. Its files are skipped by default because it may be using them.")
                    }
                }
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let note = item.note {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Text(CleanupFormat.bytes(item.bytes))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            CircleGlassButton(title: "Show in Finder", symbol: "magnifyingglass") { CleanupActions.reveal(item.url) }
                .opacity(isHovering ? 1 : 0.35)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .cleanupHoverRow(cornerRadius: 8)
        .onHover { hovering in
            guard hovering != isHovering else { return }
            isHovering = hovering
        }
        .contextMenu {
            Button("Show in Finder") { CleanupActions.reveal(item.url) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.path, forType: .string)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.name), \(CleanupFormat.bytes(item.bytes))")
    }

    private var caption: String {
        let path = CleanupFormat.path(item.url)
        guard let activity = item.lastActivity else { return path }
        return "\(CleanupFormat.idle(since: activity)) · \(path)"
    }
}
