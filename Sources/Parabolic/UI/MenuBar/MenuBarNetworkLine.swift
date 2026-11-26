import SwiftUI

/// "↓ 5.2 MB/s  ↑ 120 KB/s" for the whole Mac, with a mini graph. Clicking opens Speed Test.
struct MenuBarNetworkLine: View {
    @Environment(NetworkMonitor.self) private var network
    @Environment(SpeedTest.self) private var speedTest
    var open: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: Tokens.space2) {
                Image(systemName: speedTest.isRunning ? "gauge.with.dots.needle.67percent" : "network")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.parabolicAccent)
                    .symbolEffect(.pulse, isActive: speedTest.isRunning)
                    .frame(width: 18, height: 18)
                NetworkRatesLabel(fontSize: 11.5)
                Spacer(minLength: 0)
                // Download only: two lines each scaled to their own peak would imply equal volumes.
                Sparkline(samples: graph(network.downloadHistory), tint: NetworkRate.downloadTint)
                    .frame(width: 56, height: 16)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Tokens.space2)
            .frame(height: 30)
            .background(.primary.opacity(isHovered ? 0.07 : 0.035), in: .rect(cornerRadius: 10))
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(Tokens.quick) { isHovered = hovering } }
        .help("Live network speed for this Mac. Click to run a speed test.")
        .accessibilityHint("Opens Speed Test")
    }

    /// The last 30 seconds keeps the mini graph legible at this size.
    private func graph(_ samples: [Double]) -> [Double] {
        let recent = Array(samples.suffix(30))
        return recent.count > 1 ? recent : [0, 0]
    }
}
