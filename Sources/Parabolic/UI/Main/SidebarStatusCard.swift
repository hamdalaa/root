import SwiftUI

/// Compact glass card at the foot of the sidebar: yt-dlp status, plus live throughput while busy.
struct SidebarStatusCard: View {
    @Environment(ToolStore.self) private var tools
    @Environment(DownloadManager.self) private var manager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.space2) {
            if tools.isReady { ready } else { missing }
        }
        .padding(Tokens.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: Tokens.radiusRow)
        .animation(.adaptive(reduceMotion), value: tools.isReady)
        .animation(.adaptive(reduceMotion), value: manager.activeItems.isEmpty)
    }

    @ViewBuilder private var missing: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.space2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("yt-dlp not found")
                    .font(.system(size: 13, weight: .semibold))
                Text("Root needs it to download anything.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        if tools.isUpdating {
            HStack(spacing: Tokens.space2) {
                ProgressView().controlSize(.small)
                Text("Installing…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(height: 24)
        } else {
            Button {
                Task { await tools.installManagedYtdlp(nightly: false) }
            } label: {
                Label("Install", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .help("Download the official yt-dlp build into Application Support")
        }
        if let message = tools.lastMessage {
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .help(message)
        }
    }

    @ViewBuilder private var ready: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .imageScale(.small)
            Text("yt-dlp")
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 4)
            Text(tools.ytdlpVersion ?? "—")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)

        if !manager.activeItems.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Format.speed(manager.totalSpeed))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    Spacer(minLength: 4)
                    Text("\(manager.activeItems.count) active")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Sparkline(samples: manager.totalSpeedSamples)
                    .frame(height: 26)
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Total speed \(Format.speed(manager.totalSpeed))")
        }
    }
}
