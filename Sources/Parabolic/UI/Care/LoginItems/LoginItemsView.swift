import SwiftUI

/// Mac Care → Login Items: what starts when you log in, what's running in the background, and what's broken.
struct LoginItemsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = LoginItemsModel()

    private var query: String { appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                summary
                if let notice = model.notice { noticeBanner(notice) }
                LoginItemAppsSection(model: model, query: query)
                ForEach(LoginItemScope.allCases, id: \.self) { scope in
                    section(scope)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .animation(.adaptive(reduceMotion, Tokens.quick), value: model.notice)
        .task { model.start() }
        .onDisappear { model.stop() }
        .sheet(item: $model.pending) { pending in
            LoginItemConfirmSheet(model: model, pending: pending)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Login Items").font(.system(size: 22, weight: .semibold))
                Text("Apps and background programs that start when you log in")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer()
            Button { model.openLoginItemsSettings() } label: {
                Label("Open in System Settings", systemImage: "gear")
            }
            .buttonStyle(.glass)
            .help("System Settings → General → Login Items & Extensions")
            Button { model.reload(); model.checkAppsAccess() } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.glass)
            .disabled(model.phase == .loading)
        }
    }

    private var summary: some View {
        let ready = model.phase == .ready
        let broken = model.broken.count
        return HStack(spacing: 16) {
            StatTile(title: "Start at login", symbol: "power", value: ready ? model.automaticCount.formatted() : "—",
                     note: model.loginApps == nil ? "Background items; apps not readable yet" : "Apps and background items")
            StatTile(title: "Running now", symbol: "bolt", value: ready ? model.runningCount.formatted() : "—",
                     note: model.isLoadingStatus ? "Checking with launchd…"
                        : model.offCount > 0 ? "\(model.offCount) turned off" : "Reported by launchd")
            VStack(alignment: .leading, spacing: 6) {
                Label("Broken", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Text(ready ? broken.formatted() : "—")
                    .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(broken > 0 ? Color.red : Color.primary)
                    .contentTransition(.numericText())
                if broken > 0 {
                    Button("Remove Broken Items…") { model.requestRemove(model.broken) }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                } else {
                    Text(model.brokenElsewhere > 0 ? "\(model.brokenElsewhere) in system folders" : "Every program was found")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel(cornerRadius: 16)
            .hairline(cornerRadius: 16)
            .accessibilityElement(children: .contain)
        }
    }

    private func noticeBanner(_ notice: LoginItemsModel.Notice) -> some View {
        HStack(spacing: 8) {
            Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(notice.isError ? Color.red : Color.green)
            Text(notice.text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { model.notice = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .glassPanel(cornerRadius: Tokens.radiusRow)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func section(_ scope: LoginItemScope) -> some View {
        let all = model.entries(in: scope)
        let items = query.isEmpty ? all : all.filter {
            $0.owner.name.localizedCaseInsensitiveContains(query) || $0.label.localizedCaseInsensitiveContains(query)
        }
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(scope.title).font(.system(size: 13, weight: .semibold))
                Text(scope.folderPath).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                Spacer()
                if !scope.isManageable {
                    Button("Manage in System Settings") { model.openLoginItemsSettings() }
                        .buttonStyle(.borderless).font(.system(size: 11))
                }
            }
            .padding(.horizontal, 12)
            Group {
                if model.phase != .ready, all.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading \(scope.folderPath)…").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                } else if items.isEmpty {
                    Text(all.isEmpty ? "Nothing installed here." : "No items match “\(query)”.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, entry in
                            LoginItemEntryRow(entry: entry, model: model, showsDivider: index < items.count - 1)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .glassPanel(cornerRadius: Tokens.radiusRow)
            .hairline(cornerRadius: Tokens.radiusRow)
            if !scope.isManageable, !all.isEmpty {
                Text("Installed for every user by an administrator. Root shows them but doesn’t change them.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.horizontal, 12)
            }
        }
    }
}
