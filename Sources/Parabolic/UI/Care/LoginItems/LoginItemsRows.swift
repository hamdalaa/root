import AppKit
import SwiftUI

/// One launchd background item: owner, what it runs, when, live status, and (for your own items) a switch and actions.
struct LoginItemEntryRow: View {
    let entry: LoginItemEntry
    @Bindable var model: LoginItemsModel
    var showsDivider = true
    @State private var isHovered = false

    private var isBusy: Bool { model.busyIDs.contains(entry.id) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                icon
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(entry.owner.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        statusBadge
                    }
                    Text(entry.label).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                    detailLine
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                actions
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.primary.opacity(isHovered ? 0.035 : 0))
            .contentShape(.rect)
            .onHover { isHovered = $0 }
            .contextMenu { menuItems }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilitySummary)
            if showsDivider { Divider().padding(.leading, 58).padding(.trailing, 14) }
        }
    }

    // MARK: Pieces

    private var icon: some View {
        Group {
            if let app = entry.owner.appPath, FileManager.default.fileExists(atPath: app) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app)).resizable()
            } else {
                Image(systemName: entry.owner.kind == .developer ? "shippingbox" : "terminal")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(.primary.opacity(0.07), in: .rect(cornerRadius: 8))
            }
        }
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var statusBadge: some View {
        if entry.health.isBroken {
            UninstallerBadge(text: "Broken", symbol: "exclamationmark.triangle.fill", tint: .red)
        } else if case .volumeOffline = entry.health {
            UninstallerBadge(text: "Drive not connected", symbol: "externaldrive.badge.xmark", tint: .yellow)
        }
        switch entry.status {
        case .running(let pid):
            UninstallerBadge(text: pid > 0 ? "Running · PID \(pid)" : "Running", tint: .green)
        case .loaded(let exit):
            UninstallerBadge(text: exit.flatMap { $0 == "(never exited)" || $0 == "0" ? nil : "Loaded · exit \($0)" } ?? "Loaded",
                             tint: .secondary)
        case .notLoaded: UninstallerBadge(text: "Not loaded", tint: .secondary)
        case .disabled: UninstallerBadge(text: "Off", tint: .secondary)
        case .unknown:
            if model.isStatusPending(entry) {
                ProgressView().controlSize(.mini).accessibilityLabel("Checking status")
            }
        }
    }

    private var detailLine: some View {
        HStack(spacing: 6) {
            if let plist = entry.plist {
                Label(plist.trigger, systemImage: plist.startsAtLogin ? "power" : "clock")
                    .labelStyle(.titleAndIcon)
            }
            if let reason = entry.health.reason {
                Text(reason).foregroundStyle(entry.health.isBroken ? Color.red : Color.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(reason)
            } else if let subject = entry.subjectPath {
                Text((subject as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1).truncationMode(.middle)
                    .help(subject)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var actions: some View {
        if isBusy {
            ProgressView().controlSize(.small)
        }
        if entry.scope.isManageable {
            if entry.health.isBroken {
                Button("Remove…") { model.requestRemove([entry]) }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(isBusy)
                    .help("Move this broken item’s file to the Trash")
            } else {
                Toggle(isOn: Binding(get: { !entry.isOff }, set: { model.requestToggle(entry, on: $0) })) { EmptyView() }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .disabled(isBusy || model.isStatusPending(entry))
                    .help(entry.isOff ? "Turn on: load now and at every login" : "Turn off: stop now and skip at login")
                    .accessibilityLabel("Allow \(entry.owner.name) to run")
            }
        }
        Menu {
            menuItems
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More actions for \(entry.owner.name)")
    }

    @ViewBuilder private var menuItems: some View {
        Button("Show File in Finder") { model.revealPlist(entry) }
        Button(entry.owner.appPath != nil ? "Show App in Finder" : "Show Program in Finder") { model.revealProgram(entry) }
            .disabled(!model.programExists(entry))
        Button("Copy Label") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.label, forType: .string)
        }
        if entry.scope.isManageable {
            Divider()
            if entry.health.isBroken {
                Button("Remove Broken Item…") { model.requestRemove([entry]) }
            } else if entry.isOff {
                Button("Turn On") { model.requestToggle(entry, on: true) }
            } else {
                Button("Turn Off…") { model.requestToggle(entry, on: false) }
            }
        } else {
            Divider()
            Button("Manage in System Settings") { model.openLoginItemsSettings() }
        }
    }

    private var accessibilitySummary: String {
        var parts = [entry.owner.name, entry.status.title]
        if let plist = entry.plist { parts.append(plist.trigger) }
        if let reason = entry.health.reason { parts.append(reason) }
        return parts.joined(separator: ", ")
    }
}

/// "Apps that open at login", read through System Events, with designed permission states.
struct LoginItemAppsSection: View {
    @Bindable var model: LoginItemsModel
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Apps that open at login").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Manage in System Settings") { model.openLoginItemsSettings() }
                    .buttonStyle(.borderless).font(.system(size: 11))
            }
            .padding(.horizontal, 12)
            content
                .glassPanel(cornerRadius: Tokens.radiusRow)
                .hairline(cornerRadius: Tokens.radiusRow)
        }
    }

    @ViewBuilder private var content: some View {
        switch model.appsState {
        case .checking, .reading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Asking System Events…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        case .needsPermission:
            permissionCard(
                symbol: "lock.open",
                title: "Allow Root to read this list",
                text: "macOS keeps the “Open at Login” list behind the Automation permission. Root only reads it — names and locations, nothing is changed.",
                button: "Allow Access…") { model.readLoginApps() }
        case .denied:
            permissionCard(
                symbol: "hand.raised",
                title: "Root isn’t allowed to read this list",
                text: "Turn on System Events for Root in System Settings → Privacy & Security → Automation, or view the list in Login Items settings.",
                button: "Open Automation Settings") { model.openAutomationSettings() }
        case .failed(let message):
            permissionCard(symbol: "exclamationmark.triangle", title: "Couldn’t read the list", text: message,
                           button: "Try Again") { model.readLoginApps() }
        case .loaded(let apps):
            let shown = query.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
            if shown.isEmpty {
                Text(apps.isEmpty ? "No apps are set to open at login." : "No apps match “\(query)”.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, app in
                        LoginItemAppRow(app: app, showsDivider: index < shown.count - 1)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func permissionCard(symbol: String, title: String, text: String, button: String,
                                action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.12), in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(button, action: action).buttonStyle(.glassProminent).controlSize(.small)
                    Button("Open Login Items Settings") { model.openLoginItemsSettings() }
                        .buttonStyle(.glass).controlSize(.small)
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .accessibilityElement(children: .contain)
    }
}

private struct LoginItemAppRow: View {
    let app: LoginItemLoginApp
    var showsDivider: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Group {
                    if let path = app.path, FileManager.default.fileExists(atPath: path) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
                    } else {
                        Image(systemName: "app.dashed").font(.system(size: 20, weight: .light)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(app.name).font(.system(size: 13, weight: .semibold))
                        if app.isHidden { UninstallerBadge(text: "Opens hidden") }
                        if let path = app.path, !FileManager.default.fileExists(atPath: path) {
                            UninstallerBadge(text: "App missing", symbol: "exclamationmark.triangle.fill", tint: .red)
                        }
                    }
                    if let path = app.path {
                        Text((path as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
                if let path = app.path, FileManager.default.fileExists(atPath: path) {
                    Button { FinderReveal.reveal([URL(fileURLWithPath: path)]) } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                    .accessibilityLabel("Show \(app.name) in Finder")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            if showsDivider { Divider().padding(.leading, 58).padding(.trailing, 14) }
        }
    }
}
