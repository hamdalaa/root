import SwiftUI

/// Background apps with big footprints, each with a Quit button.
struct MemorySuggestionsCard: View {
    private var monitor: MemoryMonitor { .shared }

    var body: some View {
        let suggestions = monitor.suggestions
        StatCard(title: "Apps you could quit",
                 subtitle: "Not in front and using at least \(MemoryFormat.bytes(MemoryVerdict.worthwhileFootprint))") {
            if !monitor.hasScannedProcesses {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 80)
            } else if suggestions.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("No background app is using a lot of memory.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, group in
                        if index > 0 { Divider().padding(.leading, 40) }
                        row(group)
                    }
                }
            }
        }
        .frame(minWidth: 320)
    }

    private func row(_ group: MemoryGroup) -> some View {
        let info = group.bundlePath.flatMap { monitor.apps[$0] }
        return HStack(spacing: 10) {
            MemoryAppIcon(group: group, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(detail(group, info))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(MemoryFormat.bytes(group.footprint))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText(value: Double(group.footprint)))
            Button("Quit") { monitor.quit(group) }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("Ask \(group.name) to quit. It will offer to save unsaved work.")
                .accessibilityLabel("Quit \(group.name)")
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .contain)
    }

    private func detail(_ group: MemoryGroup, _ info: MemoryAppInfo?) -> String {
        var parts: [String] = []
        if info?.isHidden == true { parts.append("Hidden") }
        let count = group.processes.count
        parts.append(count == 1 ? "1 process" : "\(count) processes")
        return parts.joined(separator: " · ")
    }
}

/// Runs `purge` with the user's admin password and reports the measured change, even when it's tiny.
struct MemoryPurgeCard: View {
    private var monitor: MemoryMonitor { .shared }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        StatCard(title: "Free up memory", subtitle: "Flush the file cache with macOS’s purge tool") {
            VStack(alignment: .leading, spacing: 12) {
                Text("macOS asks for your administrator password, then clears cached files so more memory shows as free. It doesn’t close apps or delete anything, and macOS frees cache on its own when apps need it, so the effect is usually brief.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                status
                HStack {
                    Button {
                        Task { await monitor.freeUpMemory() }
                    } label: {
                        Label(monitor.purge == .running ? "Purging…" : "Free Up Memory…", systemImage: "sparkles")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .disabled(monitor.purge == .running)
                    .help("Runs /usr/sbin/purge as administrator")
                    if case .running = monitor.purge {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : Tokens.quick, value: monitor.purge)
    }

    @ViewBuilder private var status: some View {
        switch monitor.purge {
        case .idle, .running:
            EmptyView()
        case .cancelled:
            message("Cancelled. Nothing was changed.", symbol: "xmark.circle", tint: .secondary)
        case .failed(let error):
            message(error, symbol: "exclamationmark.triangle.fill", tint: .red)
        case .done(let result):
            VStack(alignment: .leading, spacing: 3) {
                Label(result.headline, systemImage: result.freeGain > 0 ? "arrow.up.circle.fill" : "equal.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(result.freeGain >= MemoryPurgeResult.meaningfulGain ? Color.green : Color.primary)
                Text(result.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.05), in: .rect(cornerRadius: 10))
            .accessibilityElement(children: .combine)
            .transition(.opacity)
        }
    }

    private func message(_ text: String, symbol: String, tint: Color) -> some View {
        Label {
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.system(size: 12))
        .transition(.opacity)
    }
}
