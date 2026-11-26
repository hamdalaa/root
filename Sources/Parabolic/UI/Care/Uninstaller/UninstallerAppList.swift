import SwiftUI

/// The Apps segment: filterable list on the left, the selected app's details on the right.
struct UninstallerAppsPane: View {
    @Bindable var model: UninstallerModel
    let query: String

    var body: some View {
        let apps = model.visibleApps(query: query)
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                controls
                list(apps)
            }
            .frame(minWidth: 300, maxWidth: .infinity)
            UninstallerDetailPane(model: model)
                .frame(width: 380)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
    }

    private var controls: some View {
        HStack(spacing: 6) {
            ForEach(UninstallerModel.Filter.allCases) { filter in
                UninstallerFilterChip(filter: filter, count: model.count(for: filter), isOn: model.filters.contains(filter)) {
                    model.toggle(filter)
                }
            }
            Spacer(minLength: 6)
            Menu {
                Picker("Sort by", selection: sortBinding) {
                    ForEach(UninstallerModel.Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(model.sort.rawValue, systemImage: "arrow.up.arrow.down")
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .fixedSize()
            .help("Sort apps")
            .accessibilityLabel("Sort by")
            .accessibilityValue(model.sort.rawValue)
        }
        .padding(.horizontal, 4)
    }

    private var sortBinding: Binding<UninstallerModel.Sort> {
        Binding(get: { model.sort }, set: { if $0 != model.sort { model.sort = $0 } })
    }

    @ViewBuilder
    private func list(_ apps: [UninstallApp]) -> some View {
        if model.phase == .scanning, model.apps.isEmpty {
            ProgressView("Looking in every Applications folder…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.apps.isEmpty {
            ContentUnavailableView("No apps to remove", systemImage: "app.dashed",
                                   description: Text("Apple’s apps and Root aren’t listed. Nothing else was found in your Applications folders."))
        } else if apps.isEmpty {
            if query.isEmpty {
                ContentUnavailableView {
                    Label("No apps match these filters", systemImage: "line.3.horizontal.decrease.circle")
                } actions: {
                    Button("Clear Filters") { model.filters = [] }
                }
            } else {
                ContentUnavailableView.search(text: query)
            }
        } else {
            let ids = apps.map(\.id)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(apps) { app in
                            UninstallerAppRow(app: app, size: model.sizes[app.id],
                                              isUnmeasurable: model.unmeasurable.contains(app.id),
                                              isRunning: model.isRunning(app),
                                              isSelected: model.selectedID == app.id)
                                .id(app.id)
                                .onTapGesture { model.select(app.id) }
                                .contextMenu {
                                    Button("Show in Finder") { UninstallerUI.reveal([app.url]) }
                                    Divider()
                                    Button("Uninstall…") {
                                        model.select(app.id)
                                        model.requestUninstall(app)
                                    }
                                    .disabled(model.files(for: app) == nil)
                                }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollContentBackground(.hidden)
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(.downArrow) { move(1, in: ids, proxy: proxy); return .handled }
                .onKeyPress(.upArrow) { move(-1, in: ids, proxy: proxy); return .handled }
                .onDeleteCommand {
                    if let app = model.selectedApp, model.files(for: app) != nil { model.requestUninstall(app) }
                }
                .accessibilityLabel("Apps")
            }
        }
    }

    private func move(_ delta: Int, in ids: [String], proxy: ScrollViewProxy) {
        guard !ids.isEmpty else { return }
        let current = model.selectedID.flatMap { ids.firstIndex(of: $0) } ?? (delta > 0 ? -1 : ids.count)
        let next = ids[min(max(current + delta, 0), ids.count - 1)]
        model.select(next)
        proxy.scrollTo(next)
    }
}

/// Toggleable filter capsule with a live count.
private struct UninstallerFilterChip: View {
    let filter: UninstallerModel.Filter
    let count: Int
    let isOn: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: filter.symbol).imageScale(.small)
                Text(filter.title)
                Text(count.formatted())
                    .monospacedDigit()
                    .foregroundStyle(isOn ? Color.white.opacity(0.85) : Color.secondary)
            }
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background {
                Capsule().fill(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(isHovered ? 0.10 : 0.06)))
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { isHovered = $0 }
        .accessibilityLabel(filter.title)
        .accessibilityHint(help)
        .accessibilityValue("\(count) apps")
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .help(help)
    }

    private var help: String {
        switch filter {
        case .unused: "Unused 3+ months: apps Spotlight says you haven’t opened in 90 days or more"
        case .large: "Large: apps that take 1 GB or more"
        case .external: "External: apps stored on a drive other than the startup disk"
        }
    }
}

/// One installed app: icon, name, version, where it lives, when it was last opened, and its size.
struct UninstallerAppRow: View {
    let app: UninstallApp
    let size: Int64?
    let isUnmeasurable: Bool
    let isRunning: Bool
    let isSelected: Bool
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 11) {
            Image(nsImage: UninstallerUI.icon(app.url.path))
                .resizable()
                .frame(width: 34, height: 34)
                .overlay(alignment: .bottomTrailing) {
                    if isRunning {
                        Circle().fill(.green)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                            .offset(x: 1, y: 1)
                    }
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(app.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let version = app.version {
                        Text(version).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                HStack(spacing: 5) {
                    UninstallerBadge(text: app.volume.title, symbol: app.volume.isExternal ? "externaldrive" : "internaldrive")
                    if app.isAppStore { UninstallerBadge(text: "App Store", symbol: "bag") }
                    if isRunning { UninstallerBadge(text: "Running", tint: .green) }
                    Text(UninstallerUI.lastOpened(app.lastUsed))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            sizeView
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : .primary.opacity(isHovered ? 0.05 : 0))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.55) : .clear, lineWidth: 1))
        )
        .contentShape(.rect)
        .onHover { hovering in withAnimation(.adaptive(reduceMotion, Tokens.quick)) { isHovered = hovering } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var sizeView: some View {
        if let size {
            Text(UninstallerUI.size(size))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
        } else if isUnmeasurable {
            Text("Can’t read").font(.system(size: 11)).foregroundStyle(.tertiary)
                .help("macOS didn’t let Root read this app’s contents")
        } else {
            ProgressView().controlSize(.mini)
        }
    }

    private var accessibilityText: String {
        var parts = [app.name]
        if let version = app.version { parts.append("version \(version)") }
        parts.append(app.volume.title)
        if app.isAppStore { parts.append("App Store") }
        if isRunning { parts.append("running") }
        parts.append(UninstallerUI.lastOpened(app.lastUsed))
        parts.append(size.map { UninstallerUI.size($0) } ?? (isUnmeasurable ? "size unavailable" : "measuring size"))
        return parts.joined(separator: ", ")
    }
}
