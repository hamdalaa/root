import SwiftUI

/// Mac Care → Force Quit: every open app, heaviest first, with what's stuck flagged and the means to end it.
/// The list scrolls inside its card so the Quit / Force Quit bar stays in view.
struct ForceQuitPage: View {
    @Environment(AppState.self) private var appState
    private var monitor: ForceQuitMonitor { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            summary
            ForceQuitList(query: appState.searchText)
                .frame(maxHeight: .infinity)
                .glassPanel(cornerRadius: 16)
                .hairline(cornerRadius: 16)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: 980, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await monitor.run() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Force Quit").font(.system(size: 22, weight: .semibold))
                Text("Apps open now, heaviest first. End one that’s stuck, or everything except what you need.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer()
            ForceQuitShortcutHint()
        }
    }

    private var summary: some View {
        let ready = monitor.hasSampled
        let processes = monitor.apps.reduce(0) { $0 + $1.processCount }
        let busiest = ForceQuitPolicy.busiest(monitor.apps)
        return HStack(spacing: 16) {
            StatTile(title: "Apps open", symbol: "macwindow.on.rectangle", value: ready ? monitor.apps.count.formatted() : "—",
                     note: ready ? "\(processes.formatted()) processes in all" : "Reading apps…")
            StatTile(title: "Memory used", symbol: "memorychip",
                     value: ready ? MemoryFormat.bytes(ForceQuitSummary.totalMemory(monitor)) : "—",
                     note: "Helpers included")
            StatTile(title: "Busiest", symbol: "cpu", value: busiest?.name ?? "—",
                     note: busiest?.cpuPercent.map { "\(Int($0.rounded()))% CPU now" } ?? "Measuring CPU…")
            notResponding
        }
    }

    private var notResponding: some View {
        let hung = monitor.notRespondingCount
        return VStack(alignment: .leading, spacing: 6) {
            Label("Not responding", systemImage: "exclamationmark.octagon")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Text(monitor.hasSampled ? hung.formatted() : "—")
                .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(hung > 0 ? Color.red : Color.primary)
                .contentTransition(.numericText())
            Text(hung > 0 ? "Select it, then Force Quit"
                 : "None found stuck")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 16)
        .hairline(cornerRadius: 16)
        .accessibilityElement(children: .combine)
    }
}
