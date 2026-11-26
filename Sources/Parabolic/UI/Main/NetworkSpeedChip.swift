import SwiftUI

/// Formatting shared by every live-network readout (footer chip, menu bar, Speed Test).
enum NetworkRate {
    /// "5.2 MB/s"; idle reads "0 KB/s" rather than a dash so the chip never jumps between shapes.
    static func text(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond <= 0 { return "0 KB/s" }
        if bytesPerSecond < 1000 { return "< 1 KB/s" }
        return Format.speed(bytesPerSecond)
    }

    /// "245" / "8.4" for megabits per second.
    static func mbps(_ value: Double?) -> String {
        guard let value, value > 0 else { return "—" }
        return value < 10 ? value.formatted(.number.precision(.fractionLength(1)))
                          : value.formatted(.number.precision(.fractionLength(0)))
    }

    /// "12" for milliseconds.
    static func ms(_ value: Double?) -> String {
        guard let value, value > 0 else { return "—" }
        return value < 10 ? value.formatted(.number.precision(.fractionLength(1)))
                          : value.formatted(.number.precision(.fractionLength(0)))
    }

    static let downloadTint = Color.accentColor
    static let uploadTint = Color.teal
}

/// "↓ 5.2 MB/s  ↑ 120 KB/s": system-wide throughput, quiet and monospaced.
struct NetworkRatesLabel: View {
    @Environment(NetworkMonitor.self) private var network
    var fontSize: CGFloat = 11.5

    var body: some View {
        HStack(spacing: 10) {
            rate(network.downloadBytesPerSecond, symbol: "arrow.down", tint: NetworkRate.downloadTint, fixedWidth: true)
            rate(network.uploadBytesPerSecond, symbol: "arrow.up", tint: NetworkRate.uploadTint, fixedWidth: false)
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Network:\(NetworkRate.text(network.downloadBytesPerSecond)) down, \(NetworkRate.text(network.uploadBytesPerSecond)) up")
    }

    /// `fixedWidth` reserves room on the first value so the one after it doesn't shift every second.
    private func rate(_ value: Double, symbol: String, tint: Color, fixedWidth: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: fontSize - 2, weight: .bold))
                .foregroundStyle(tint.opacity(value > 0 ? 0.95 : 0.6))
            Text(NetworkRate.text(value))
                .font(.system(size: fontSize, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText(value: value))
                .frame(minWidth: fixedWidth ? fontSize * 4.8 : nil, alignment: .leading)
        }
    }
}

/// Footer chip on the downloads screen. Clicking it opens Speed Test.
struct NetworkSpeedChip: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : Tokens.motion) { appState.sidebarSelection = .speedTest }
        } label: {
            NetworkRatesLabel()
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(Capsule().fill(.primary.opacity(isHovered ? 0.06 : 0)))
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .onHover { hovering in withAnimation(reduceMotion ? nil : Tokens.quick) { isHovered = hovering } }
        .help("Live network speed for this Mac. Click to run a speed test.")
        .accessibilityHint("Opens Speed Test")
    }
}

// MARK: - File categories

extension FileCategory {
    var symbol: String {
        switch self {
        case .video: "film"
        case .music: "music.note"
        case .documents: "doc.text"
        case .archives: "archivebox"
        case .apps: "app.badge"
        case .images: "photo"
        case .torrents: "point.3.connected.trianglepath.dotted"
        case .other: "doc"
        }
    }
}
