import AppKit
import SwiftUI

/// The running-apps list with its actions, shared by the Mac Care page and the ⌃⌥⌘⎋ panel: apps sorted by memory
/// (helpers included), CPU, a "Not Responding" badge, Quit, Force Quit (SIGKILL fallback), Force Quit All Except.
/// Click rows to select them. Every force quit asks first. No Return shortcut: a stray keystroke can't end an app.
struct ForceQuitList: View {
    var query = ""
    @State private var selection: Set<pid_t> = []
    @State private var pending: PendingAction?
    private var monitor: ForceQuitMonitor { .shared }

    private enum PendingAction: Identifiable {
        case forceQuit([ForceQuitApp])
        case forceQuitAll(except: Set<pid_t>, targets: [ForceQuitApp])
        var id: String {
            switch self {
            case .forceQuit(let apps): "one-" + apps.map { String($0.pid) }.joined(separator: ",")
            case .forceQuitAll(_, let targets): "all-" + targets.map { String($0.pid) }.joined(separator: ",")
            }
        }
    }

    private var selectedApps: [ForceQuitApp] {
        monitor.apps.filter { selection.contains($0.pid) && ForceQuitPolicy.canQuit($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            columnTitles
            Divider().padding(.horizontal, Tokens.space3)
            list
            Divider()
            footer
                .padding(.horizontal, Tokens.space4)
                .padding(.vertical, Tokens.space3)
        }
        .alert(alertTitle, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
               presenting: pending) { action in
            Button(confirmTitle(action), role: .destructive) { perform(action) }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(confirmMessage(action))
        }
        .onChange(of: monitor.apps) { _, apps in
            let alive = Set(apps.map(\.pid))
            if !selection.isSubset(of: alive) { selection.formIntersection(alive) }
        }
    }

    private var columnTitles: some View {
        HStack(spacing: 0) {
            Text("App").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 46)
            Text("CPU").frame(width: ForceQuitRow.cpuWidth, alignment: .trailing)
            Text("Memory ↓").frame(width: ForceQuitRow.memoryWidth, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, Tokens.space4)
        .padding(.top, Tokens.space3)
        .padding(.bottom, 6)
        .accessibilityHidden(true)
    }

    // MARK: List

    @ViewBuilder private var list: some View {
        let apps = ForceQuitPolicy.filter(monitor.apps, query: query)
        if !monitor.hasSampled {
            ProgressView("Reading running apps…")
                .controlSize(.small)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if apps.isEmpty {
            ContentUnavailableView.search(text: query)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(apps) { app in
                        ForceQuitRow(app: app, isEnding: monitor.ending.contains(app.pid),
                                     isSelected: selection.contains(app.pid)) { toggle(app) }
                            .contextMenu { rowMenu(app) }
                    }
                }
                .padding(.horizontal, Tokens.space2)
                .padding(.vertical, 6)
            }
            .scrollContentBackground(.hidden)
        }
    }

    private func toggle(_ app: ForceQuitApp) {
        guard ForceQuitPolicy.canQuit(app) else { return }
        if selection.contains(app.pid) { selection.remove(app.pid) } else { selection.insert(app.pid) }
    }

    @ViewBuilder private func rowMenu(_ app: ForceQuitApp) -> some View {
        if ForceQuitPolicy.canQuit(app) {
            Button("Quit \(app.name)") { monitor.quit(app) }
            Button("Force Quit \(app.name)…") { pending = .forceQuit([app]) }
            Divider()
            Button("Force Quit All Except \(app.name)…") { askQuitAll(except: [app.pid]) }
        }
        if let path = app.bundlePath {
            Divider()
            Button("Show in Finder") { FinderReveal.reveal([URL(fileURLWithPath: path)]) }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Tokens.space2) {
            if let notice = monitor.notice {
                Label(notice, systemImage: "checkmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .transition(.opacity)
            } else {
                Text(selection.isEmpty ? "Click apps to select them." : "\(selectedApps.count) selected")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Tokens.space2)
            Button(selection.isEmpty ? "Force Quit All…" : "Force Quit All Except Selected…") {
                askQuitAll(except: selection)
            }
            .buttonStyle(.glass)
            .disabled(ForceQuitPolicy.targetsForQuitAll(monitor.apps, keeping: selection).isEmpty)
            .help("Ends every other app at once. Finder, the Dock and Root stay open.")
            Button("Quit") { selectedApps.forEach(monitor.quit) }
                .buttonStyle(.glass)
                .disabled(selectedApps.isEmpty)
                .help("Asks the app to quit. It may ask to save first.")
            Button("Force Quit") { pending = .forceQuit(selectedApps) }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .disabled(selectedApps.isEmpty)
                .help("Ends the app now. Unsaved changes are lost.")
        }
        .controlSize(.large)
        .animation(Tokens.quick, value: monitor.notice)
    }

    // MARK: Confirm

    private func askQuitAll(except kept: Set<pid_t>) {
        let targets = ForceQuitPolicy.targetsForQuitAll(monitor.apps, keeping: kept)
        guard !targets.isEmpty else { return }
        pending = .forceQuitAll(except: kept, targets: targets)
    }

    private var alertTitle: String {
        switch pending {
        case .forceQuit(let apps) where apps.count == 1: "Force quit \(apps[0].name)?"
        case .forceQuit(let apps): "Force quit \(apps.count) apps?"
        case .forceQuitAll(let kept, _): kept.isEmpty ? "Force quit all apps?" : "Force quit all apps except the selected?"
        case nil: ""
        }
    }

    private func confirmTitle(_ action: PendingAction) -> String {
        switch action {
        case .forceQuit: "Force Quit"
        case .forceQuitAll(_, let targets): "Force Quit \(targets.count)"
        }
    }

    private func confirmMessage(_ action: PendingAction) -> String {
        switch action {
        case .forceQuit(let apps): ForceQuitPolicy.confirmMessage(for: apps)
        case .forceQuitAll(_, let targets): ForceQuitPolicy.confirmMessage(for: targets)
        }
    }

    private func perform(_ action: PendingAction) {
        switch action {
        case .forceQuit(let apps):
            Task { await withTaskGroup(of: Void.self) { group in
                for app in apps { group.addTask { @MainActor in await monitor.forceQuit(app) } }
            } }
        case .forceQuitAll(let kept, _):
            Task { await monitor.forceQuitAll(except: kept) }
        }
        selection = []
    }
}

/// One app: icon, name with its badges and helper count, CPU, memory. Accent fill when selected.
struct ForceQuitRow: View {
    static let cpuWidth: CGFloat = 64
    static let memoryWidth: CGFloat = 92

    var app: ForceQuitApp
    var isEnding: Bool
    var isSelected: Bool
    var toggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Tokens.space3) {
            ForceQuitAppIcon(pid: app.pid, path: app.bundlePath)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(app.name)
                        .font(.system(size: 13, weight: app.isResponding == false ? .semibold : .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if app.isResponding == false {
                        Text("Not Responding")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.red, in: .capsule)
                            .fixedSize()
                    }
                    if isEnding { ProgressView().controlSize(.mini) }
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(cpuText)
                .foregroundStyle(isBusy ? .primary : .secondary)
                .fontWeight(isBusy ? .semibold : .regular)
                .frame(width: Self.cpuWidth, alignment: .trailing)
            Text(MemoryFormat.bytes(app.memory))
                .fontWeight(.medium)
                .frame(width: Self.memoryWidth, alignment: .trailing)
        }
        .font(.system(size: 12).monospacedDigit())
        .padding(.horizontal, Tokens.space2)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fill))
        .contentShape(.rect(cornerRadius: 10))
        .opacity(app.isSelf ? 0.55 : 1)
        .onHover { isHovered = $0 }
        .onTapGesture(perform: toggle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, toggle)
    }

    private var fill: Color {
        if isSelected { return Color.parabolicAccent.opacity(0.22) }
        return .primary.opacity(isHovered && ForceQuitPolicy.canQuit(app) ? 0.05 : 0)
    }

    private var detail: String {
        if app.isSelf { return "This app" }
        return app.processCount > 1 ? "\(app.processCount) processes" : "1 process"
    }

    private var cpuText: String {
        guard let cpu = app.cpuPercent else { return "–" }
        return cpu >= 10 ? "\(Int(cpu.rounded()))%" : String(format: "%.1f%%", cpu)
    }

    private var isBusy: Bool { (app.cpuPercent ?? 0) >= 80 }

    private var accessibilityText: String {
        var parts = [app.name]
        if app.isResponding == false { parts.append("not responding") }
        parts.append("memory \(MemoryFormat.bytes(app.memory))")
        if let cpu = app.cpuPercent { parts.append("CPU \(Int(cpu.rounded())) percent") }
        return parts.joined(separator: ", ")
    }
}

private struct ForceQuitAppIcon: View {
    var pid: pid_t
    var path: String?

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .interpolation(.high)
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
    }

    private var icon: NSImage {
        if let image = NSRunningApplication(processIdentifier: pid)?.icon { return image }
        if let path { return NSWorkspace.shared.icon(forFile: path) }
        return NSWorkspace.shared.icon(for: .application)
    }
}
