import SwiftUI

/// Support files from apps that are no longer installed, grouped by the app that made them.
struct UninstallerLeftoversPane: View {
    @Bindable var model: UninstallerModel
    let query: String

    private var groups: [UninstallLeftoverGroup] {
        guard !query.isEmpty else { return model.leftoverGroups }
        return model.leftoverGroups.filter {
            $0.displayName.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        Group {
            switch model.leftoverPhase {
            case .idle, .scanning:
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(model.phase == .ready ? "Checking your Library against \(model.apps.count) installed apps…"
                                                : "Waiting for the app list…")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { if model.leftoverPhase == .idle, model.phase == .ready { model.scanLeftovers() } }
                .onChange(of: model.phase) { _, phase in
                    if phase == .ready, model.leftoverPhase == .idle { model.scanLeftovers() }
                }
            case .ready:
                if model.leftoverGroups.isEmpty {
                    ContentUnavailableView("No leftovers found", systemImage: "checkmark.seal",
                                           description: Text(Self.rules))
                } else if groups.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    list
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
    }

    static let rules = "Only items named like an app identifier (com.developer.app) are considered. They’re listed when no app on this Mac matches, no app from the same developer is installed, and nothing in them changed in the last 30 days. Apple’s files are never listed."

    private var list: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(groups) { group in
                        UninstallerLeftoverGroupView(
                            group: group, model: model,
                            isExpanded: Binding(get: { model.expandedGroups.contains(group.id) }, set: { value in
                                guard value != model.expandedGroups.contains(group.id) else { return }
                                if value { model.expandedGroups.insert(group.id) } else { model.expandedGroups.remove(group.id) }
                            }))
                    }
                    Text(Self.rules)
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8).padding(.top, 6)
                }
                .padding(.vertical, 4)
            }
            .scrollContentBackground(.hidden)
            footer
        }
    }

    private var footer: some View {
        let items = model.checkedLeftovers
        let bytes = items.compactMap(\.bytes).reduce(0, +)
        let all = model.leftoverGroups.flatMap(\.items).count
        return HStack(spacing: 12) {
            Button(items.count == all ? "Select None" : "Select All") { model.setAllLeftovers(checked: items.count != all) }
                .buttonStyle(.glass)
            Text("\(items.count) of \(all) selected")
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            Button { model.requestLeftoverRemoval() } label: {
                Text(items.isEmpty ? "Move to Trash" : "Move \(UninstallerUI.size(bytes)) to Trash")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(items.isEmpty)
        }
        .padding(12)
        .glassPanel(cornerRadius: 16)
        .hairline(cornerRadius: 16)
        .padding(.top, 6)
    }
}

/// A probable app with its leftover items; the header checkbox covers the whole group.
private struct UninstallerLeftoverGroupView: View {
    let group: UninstallLeftoverGroup
    @Bindable var model: UninstallerModel
    @Binding var isExpanded: Bool
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var checkedCount: Int { group.items.filter { model.leftoverChecked.contains($0.id) }.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Toggle(isOn: Binding(get: { checkedCount == group.items.count },
                                     set: { model.setGroup(group, checked: $0) })) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .accessibilityLabel("Remove everything from \(group.displayName)")
                    .accessibilityValue("\(checkedCount) of \(group.items.count) selected")
                Image(systemName: "app.dashed")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.secondary)
                    .frame(width: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(UninstallerUI.size(group.bytes))
                    .font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(.rect)
            .onTapGesture { withAnimation(.adaptive(reduceMotion, Tokens.quick)) { isExpanded.toggle() } }
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: isExpanded ? "Collapse" : "Expand") { isExpanded.toggle() }

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(group.items) { item in itemRow(item) }
                }
                .padding(.leading, 40)
                .padding(.trailing, 8)
                .padding(.bottom, 6)
                .transition(.opacity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.primary.opacity(isHovered || isExpanded ? 0.05 : 0.025))
        )
        .onHover { isHovered = $0 }
    }

    private var subtitle: String {
        let count = group.items.count
        let when = group.newest.map { " · last changed " + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""
        return "\(group.id) · \(count) item\(count == 1 ? "" : "s")\(when)"
    }

    private func itemRow(_ item: UninstallLeftoverItem) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { model.leftoverChecked.contains(item.id) },
                                 set: { model.setLeftover(item, checked: $0) })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Remove \(item.url.lastPathComponent)")
            Image(systemName: item.kind.symbol).font(.system(size: 11)).foregroundStyle(Color.accentColor).frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.url.lastPathComponent).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Text([item.kind.title, UninstallerUI.linkNote(item.link)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(item.link.target.map { "\(item.url.path) → \($0.path)" } ?? item.url.path)
            Button { UninstallerUI.reveal([item.link.target ?? item.url]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Show in Finder")
                .accessibilityLabel("Show \(item.url.lastPathComponent) in Finder")
            Text(UninstallerUI.linkSizeLabel(item.link) ?? UninstallerUI.size(item.bytes))
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                .frame(minWidth: 58, alignment: .trailing)
                .help(UninstallerUI.linkHelp(item.link))
        }
        .padding(.vertical, 4)
    }
}
