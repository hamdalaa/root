import SwiftUI

/// Every category as a row: tick, size, and a disclosure with the individual items.
struct CleanupCategoryList: View {
    @Bindable var store: CleanupStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(store.phase == .scanning ? "Checking" : "Categories")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
            VStack(spacing: 0) {
                let categories = orderedCategories
                ForEach(Array(categories.enumerated()), id: \.element) { index, category in
                    CleanupCategoryRow(store: store, category: category, showsDivider: index < categories.count - 1)
                }
            }
            .padding(.vertical, 4)
            .glassPanel(cornerRadius: Tokens.radiusRow)
            .hairline(cornerRadius: Tokens.radiusRow)
        }
        .animation(.adaptive(reduceMotion), value: store.expanded)
    }

    /// Fixed order while scanning so rows don't jump; largest first once everything is in.
    private var orderedCategories: [CleanupCategoryID] {
        let all = CleanupCategoryID.allCases
        guard store.phase == .ready else { return all }
        return all.sorted { lhs, rhs in
            let a = store.results[lhs]?.totalBytes ?? -1
            let b = store.results[rhs]?.totalBytes ?? -1
            return a == b ? all.firstIndex(of: lhs)! < all.firstIndex(of: rhs)! : a > b
        }
    }
}

private struct CleanupCategoryRow: View {
    @Bindable var store: CleanupStore
    let category: CleanupCategoryID
    let showsDivider: Bool

    private var result: CleanupCategoryResult? { store.results[category] }
    private var state: CleanupStore.CategoryState? { store.categoryStates[category] }
    private var isExpanded: Bool { store.expanded.contains(category) }
    private var hasItems: Bool { !(result?.items.isEmpty ?? true) }
    /// Project artifacts stays expandable when empty so its idle-time setting can still be changed.
    private var isInteractive: Bool { store.phase == .ready && (hasItems || category == .projectArtifacts) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if store.phase == .ready {
                    CleanupCheckbox(mark: store.mark(for: category), label: category.title) { store.toggle(category) }
                        .disabled(!hasItems)
                        .opacity(hasItems ? 1 : 0.4)
                }
                Button {
                    guard isInteractive else { return }
                    store.toggleExpanded(category)
                } label: {
                    rowLabel
                }
                .buttonStyle(.plain)
                .disabled(!isInteractive)
                .accessibilityLabel(category.title)
                .accessibilityValue(accessibilityValue)
                .accessibilityHint(isInteractive ? (isExpanded ? "Hides the items" : "Shows the items") : "")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .cleanupHoverRow()
            .padding(.horizontal, 2)

            if isExpanded, let result {
                CleanupItemList(store: store, result: result)
                    .padding(.leading, 44)
                    .padding(.trailing, 12)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if showsDivider {
                Divider().padding(.leading, store.phase == .ready ? 86 : 54).padding(.trailing, 14)
            }
        }
    }

    private var rowLabel: some View {
        HStack(spacing: 12) {
            CleanupSymbolTile(symbol: category.symbol, isActive: state != .done || hasItems)
            VStack(alignment: .leading, spacing: 2) {
                Text(category.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(state == .done && !hasItems ? .secondary : .primary)
                subtitle
            }
            Spacer(minLength: 12)
            trailing
            if isInteractive {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
        }
        .contentShape(.rect)
    }

    @ViewBuilder private var subtitle: some View {
        if let result, result.deniedCount > 0, state == .done {
            Label("\(result.deniedCount.formatted()) folder\(result.deniedCount == 1 ? "" : "s") couldn’t be read",
                  systemImage: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .labelStyle(CleanupInlineLabelStyle())
        } else if store.phase == .ready, let caution = category.caution, hasItems {
            Text(caution)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(category.summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch state {
        case .scanning:
            ProgressView().controlSize(.small)
                .transition(.opacity)
        case .done:
            if let result, hasItems {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(CleanupFormat.bytes(result.totalBytes))
                        .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                    Text(selectionCaption(result))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
            } else {
                Text("Nothing found")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        case .waiting, nil:
            Text("—").foregroundStyle(.tertiary)
        }
    }

    private func selectionCaption(_ result: CleanupCategoryResult) -> String {
        let selected = result.items.filter { store.isSelected($0) }.count
        if store.phase != .ready { return CleanupFormat.items(result.items.count) }
        if selected == 0 { return "\(CleanupFormat.items(result.items.count)), none ticked" }
        if selected == result.items.count { return CleanupFormat.items(selected) }
        return "\(selected) of \(result.items.count) ticked"
    }

    private var accessibilityValue: String {
        switch state {
        case .scanning: return "Scanning"
        case .done:
            guard let result, hasItems else { return "Nothing found" }
            return "\(CleanupFormat.bytes(result.totalBytes)), \(selectionCaption(result))"
        default: return "Waiting"
        }
    }
}

/// Icon and text on one baseline at caption size.
struct CleanupInlineLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}
