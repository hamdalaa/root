import SwiftUI

/// Floating glass bar at the bottom of the list: live totals, conversions and one grouped capsule of bulk actions.
struct DownloadsFooterBar: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(ConversionStore.self) private var conversions
    let actions: DownloadActions

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                if !manager.items.isEmpty { summary }
                NetworkSpeedChip()
                if !conversions.jobs.isEmpty {
                    ConversionsPill()
                }
                Spacer(minLength: 10)
                if !manager.items.isEmpty {
                    // Titles when there's room, icons only when narrow. No measured widths (layout loops).
                    ViewThatFits(in: .horizontal) {
                        buttons(showsTitles: true)
                        buttons(showsTitles: false)
                    }
                }
            }
        }
        .frame(maxWidth: 760)
    }

    private var summary: some View {
        let active = manager.activeItems.count
        return HStack(spacing: 8) {
            Circle()
                .fill(active > 0 ? Color.accentColor : Color.secondary.opacity(0.45))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(summaryText(active: active))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .lineLimit(1)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
    }

    private func summaryText(active: Int) -> String {
        guard active > 0 else {
            let count = manager.items.count
            return "\(count) download\(count == 1 ? "" : "s")"
        }
        return "\(active) active · \(Format.speed(manager.totalSpeed))"
    }

    private func buttons(showsTitles: Bool) -> some View {
        let items = manager.items
        let hasFinished = items.contains { $0.status.isFinished }
        let hasFailed = items.contains { $0.status == .failed }
        let canPause = items.contains(where: \.canPause)
        let canResume = items.contains { $0.status == .paused || $0.status == .stopped }
        return HStack(spacing: 0) {
            FooterButton(title: "Retry Failed", symbol: "arrow.clockwise", showsTitle: false, enabled: hasFailed) {
                manager.retryFailed()
            }
            FooterButton(title: "Clear Finished", symbol: "checkmark.circle.badge.xmark", showsTitle: false, enabled: hasFinished) {
                manager.clearFinished()
            }
            Divider().frame(height: 16).padding(.horizontal, 4)
            FooterButton(title: "Pause All", symbol: "pause.fill", showsTitle: showsTitles, enabled: canPause) {
                manager.pauseAll()
            }
            FooterButton(title: "Resume All", symbol: "play.fill", showsTitle: showsTitles, enabled: canResume) {
                manager.resumeAll()
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 34)
        .glassEffect(.regular, in: .capsule)
    }
}

/// Plain button inside a shared glass capsule, with its own hover highlight.
private struct FooterButton: View {
    let title: String
    let symbol: String
    var showsTitle: Bool
    var enabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 14)
                if showsTitle {
                    Text(title).font(.system(size: 12, weight: .medium))
                }
            }
            .padding(.horizontal, showsTitle ? 10 : 7)
            .frame(height: 26)
            .background(Capsule().fill(.primary.opacity(isHovered && enabled ? 0.08 : 0)))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .primary : .tertiary)
        .disabled(!enabled)
        .onHover { isHovered = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}
