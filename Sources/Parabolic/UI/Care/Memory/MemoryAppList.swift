import AppKit
import SwiftUI

/// Every measured process, rolled up under the app it belongs to. Search, sort, expand, quit.
struct MemoryAppListCard: View {
    private var monitor: MemoryMonitor { .shared }
    @State private var query = ""
    @State private var order: MemorySortOrder = .memory
    @State private var expanded: Set<String> = []
    @State private var showsAll = false
    @State private var forceQuitTarget: MemoryGroup?
    @State private var forceKillTarget: MemoryProcess?

    private static let collapsedLimit = 14

    var body: some View {
        let groups = monitor.groups.memoryFiltered(query, order: order)
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let visible = searching || showsAll ? groups : Array(groups.prefix(Self.collapsedLimit))
        let largest = monitor.groups.map(\.footprint).max() ?? 1
        VStack(alignment: .leading, spacing: 14) {
            toolbar
            if !monitor.hasScannedProcesses {
                ProgressView("Reading processes…")
                    .controlSize(.small)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if groups.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(minHeight: 160)
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, group in
                        if group.isTool, index == 0 || !visible[index - 1].isTool { MemoryToolsHeader() }
                        MemoryGroupRow(group: group, info: group.bundlePath.flatMap { monitor.apps[$0] },
                                       largest: largest, isExpanded: expanded.contains(group.id),
                                       toggle: { toggle(group.id) },
                                       forceQuit: { forceQuitTarget = group },
                                       forceKill: { forceKillTarget = $0 })
                    }
                }
                if !searching && groups.count > Self.collapsedLimit {
                    Button(showsAll ? "Show fewer" : "Show all \(groups.count) groups") { showsAll.toggle() }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                        .padding(.leading, 6)
                }
            }
            footer
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 16)
        .hairline(cornerRadius: 16)
        .animation(Tokens.quick, value: expanded)
        .confirmationDialog(forceQuitTitle, isPresented: forceQuitBinding, titleVisibility: .visible,
                            presenting: forceQuitTarget) { group in
            Button("Force Quit \(group.name)", role: .destructive) { monitor.forceQuit(group) }
            Button("Cancel", role: .cancel) {}
        } message: { group in
            Text(forceQuitMessage(group))
        }
        .confirmationDialog(forceKillTitle, isPresented: forceKillBinding, titleVisibility: .visible,
                            presenting: forceKillTarget) { process in
            Button("Force Quit \(process.name)", role: .destructive) { monitor.signal(process, force: true) }
            Button("Cancel", role: .cancel) {}
        } message: { process in
            Text("Process \(process.pid) (\(process.path ?? process.name)) stops immediately and can’t save or clean up. Anything it was doing is lost. This frees about \(MemoryFormat.bytes(process.footprint ?? 0)).")
        }
    }

    private var toolbar: some View {
        let measured = monitor.groups.reduce(0) { $0 + $1.processes.count }
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("By app").font(.system(size: 13, weight: .semibold))
                Text("\(monitor.groups.filter { $0.kind == .app }.count) apps · \(monitor.groups.filter(\.isTool).count) command-line tools · \(measured) processes measured")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search apps and processes", text: $query)
                    .textFieldStyle(.plain)
                    .frame(width: 180)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Clear search")
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .glassCapsule()
            Picker("Sort by", selection: $order) {
                ForEach(MemorySortOrder.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("Sort by")
        }
    }

    private var footer: some View {
        let total = monitor.groups.reduce(UInt64(0)) { $0 + $1.footprint }
        var lines = ["Measured processes add up to \(MemoryFormat.bytes(total)). Shared memory counts once per process, so this can differ from Memory used."]
        if monitor.unreadableProcesses > 0 {
            let n = monitor.unreadableProcesses
            lines.append("\(n) process\(n == 1 ? "" : "es") owned by macOS or other users can’t be measured without administrator rights and aren’t listed.")
        }
        return Text(lines.joined(separator: " "))
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6)
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private var forceQuitBinding: Binding<Bool> {
        Binding(get: { forceQuitTarget != nil },
                set: { presented in if !presented, forceQuitTarget != nil { forceQuitTarget = nil } })
    }

    private var forceKillBinding: Binding<Bool> {
        Binding(get: { forceKillTarget != nil },
                set: { presented in if !presented, forceKillTarget != nil { forceKillTarget = nil } })
    }

    private var forceKillTitle: String {
        forceKillTarget.map { "Force quit \($0.name) (PID \($0.pid))?" } ?? "Force quit?"
    }

    private var forceQuitTitle: String {
        forceQuitTarget.map { "Force quit \($0.name)?" } ?? "Force quit?"
    }

    private func forceQuitMessage(_ group: MemoryGroup) -> String {
        let helpers = group.processes.count - 1
        let helperText = helpers > 0 ? " and its \(helpers) helper process\(helpers == 1 ? "" : "es")" : ""
        return "\(group.name)\(helperText) will stop immediately without saving. Unsaved changes in \(group.name) will be lost. This frees about \(MemoryFormat.bytes(group.footprint))."
    }
}

// MARK: - Row

private struct MemoryGroupRow: View {
    let group: MemoryGroup
    let info: MemoryAppInfo?
    let largest: UInt64
    let isExpanded: Bool
    let toggle: () -> Void
    let forceQuit: () -> Void
    let forceKill: (MemoryProcess) -> Void

    private var monitor: MemoryMonitor { .shared }
    @State private var isHovered = false

    private var canQuit: Bool { info?.canQuit == true }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(group.processes.prefix(60)) {
                        MemoryProcessRow(process: $0, allowsSignals: group.isTool, forceKill: forceKill)
                    }
                    if group.processes.count > 60 {
                        Text("and \(group.processes.count - 60) more")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 68).padding(.vertical, 4)
                    }
                }
                .padding(.bottom, 6)
                .transition(.opacity)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.primary.opacity(isExpanded ? 0.05 : (isHovered ? 0.04 : 0))))
        .onHover { isHovered = $0 }
        .contextMenu { menuItems }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)
                    MemoryAppIcon(group: group, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(group.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            if group.isTool, group.processes.count > 1 {
                                Text("×\(group.processes.count)")
                                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(group.name), \(MemoryFormat.bytes(group.footprint)), \(subtitle)")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows the processes in this group")

            if isHovered || isExpanded { actions.transition(.opacity) }

            MemoryShareBar(fraction: largest > 0 ? Double(group.footprint) / Double(largest) : 0)
                .frame(width: 90, height: 5)
                .accessibilityHidden(true)
            Text(MemoryFormat.bytes(group.footprint))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .frame(width: 76, alignment: .trailing)
                .contentTransition(.numericText(value: Double(group.footprint)))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .animation(Tokens.quick, value: isHovered)
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            if canQuit {
                Button("Quit \(group.name)") { monitor.quit(group) }
                Button("Force Quit \(group.name)") { forceQuit() }
            }
            if let path = group.bundlePath { Button("Reveal in Finder") { monitor.reveal(path) } }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if group.isTool, !group.hostNames.isEmpty { parts.append("from " + group.hostNames.joined(separator: ", ")) }
        if info?.isSelf == true { parts.append("This app") }
        else if info?.isActive == true { parts.append("In front") }
        else if info?.isHidden == true { parts.append("Hidden") }
        else if group.kind == .app && info == nil { parts.append("Background") }
        let count = group.processes.count
        parts.append(count == 1 ? "1 process" : "\(count) processes")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 4) {
            if canQuit {
                CircleGlassButton(title: "Quit \(group.name)", symbol: "xmark") { monitor.quit(group) }
                CircleGlassButton(title: "Force Quit \(group.name)…", symbol: "bolt.fill", tint: .red) { forceQuit() }
            }
            if let path = group.bundlePath {
                CircleGlassButton(title: "Reveal in Finder", symbol: "magnifyingglass") { monitor.reveal(path) }
            }
        }
    }

    @ViewBuilder private var menuItems: some View {
        if canQuit {
            Button("Quit \(group.name)") { monitor.quit(group) }
            Button("Force Quit \(group.name)…") { forceQuit() }
            Divider()
        }
        if let path = group.bundlePath { Button("Reveal in Finder") { monitor.reveal(path) } }
        Button(isExpanded ? "Hide Processes" : "Show Processes", action: toggle)
    }
}

private struct MemoryProcessRow: View {
    let process: MemoryProcess
    /// Per-process Quit / Force Quit (command-line tools only).
    let allowsSignals: Bool
    let forceKill: (MemoryProcess) -> Void
    private var monitor: MemoryMonitor { .shared }
    @State private var isHovered = false

    private var canSignal: Bool { allowsSignals && monitor.canSignal(process) }

    var body: some View {
        HStack(spacing: 8) {
            Text(process.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("PID \(process.pid)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            if canSignal, isHovered {
                HStack(spacing: 4) {
                    CircleGlassButton(title: "Quit \(process.name) (PID \(process.pid))", symbol: "xmark") {
                        monitor.signal(process, force: false)
                    }
                    CircleGlassButton(title: "Force Quit \(process.name) (PID \(process.pid))…", symbol: "bolt.fill", tint: .red) {
                        forceKill(process)
                    }
                }
                .transition(.opacity)
            }
            Text(process.footprint.map(MemoryFormat.bytes) ?? "—")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.leading, 68)
        .padding(.trailing, 8)
        .frame(height: 26)
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .animation(Tokens.quick, value: isHovered)
        .help(process.path ?? process.name)
        .contextMenu {
            if canSignal {
                Button("Quit \(process.name)") { monitor.signal(process, force: false) }
                Button("Force Quit \(process.name)…") { forceKill(process) }
                Divider()
            }
            if let path = process.path { Button("Reveal Executable in Finder") { monitor.reveal(path) } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            if canSignal {
                Button("Quit \(process.name)") { monitor.signal(process, force: false) }
                Button("Force Quit \(process.name)") { forceKill(process) }
            }
        }
    }
}

/// Section label above the command-line tools.
private struct MemoryToolsHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Command-line tools").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Text("Started from a terminal or editor. Counted on their own, not as part of the app that launched them.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Bits

private struct MemoryShareBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                Capsule().fill(Color.accentColor.gradient)
                    .frame(width: max(3, proxy.size.width * min(1, max(0, fraction))))
            }
        }
    }
}

/// The app's Finder icon, or a gear for the system bucket.
struct MemoryAppIcon: View {
    let group: MemoryGroup
    let size: CGFloat

    var body: some View {
        Group {
            if let path = group.bundlePath {
                Image(nsImage: MemoryIconCache.icon(for: path))
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: group.isTool ? "terminal.fill" : "gearshape.2.fill")
                    .font(.system(size: size * 0.48, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(.primary.opacity(0.07), in: .rect(cornerRadius: size * 0.24, style: .continuous))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

@MainActor
private enum MemoryIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for path: String) -> NSImage {
        if let cached = cache[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache[path] = image
        return image
    }
}
