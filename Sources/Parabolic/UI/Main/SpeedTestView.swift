import SwiftUI

/// Internet speed test: a big gauge, ping / jitter / download / upload, live system throughput and past results.
struct SpeedTestView: View {
    @Environment(SpeedTest.self) private var test
    @Environment(DownloadManager.self) private var manager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                hero
                SpeedResultTiles()
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        LiveNetworkCard()
                        SpeedHistoryCard()
                    }
                    VStack(spacing: 16) {
                        LiveNetworkCard()
                        SpeedHistoryCard()
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .animation(reduceMotion ? nil : Tokens.motion, value: test.phase)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Speed Test")
                .font(.system(size: 22, weight: .semibold))
            Text("Measured against Cloudflare’s global network")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 18) {
            SpeedPhaseSteps(phase: test.phase)
            SpeedGauge(mbps: gaugeValue, readout: readout, unit: unit, caption: caption,
                       tint: test.phase == .upload ? NetworkRate.uploadTint : NetworkRate.downloadTint,
                       isActive: test.isRunning)
            statusLine
                .frame(minHeight: 36)
            actionButton
        }
        .padding(.vertical, 24)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .glassPanel(cornerRadius: 24)
        .hairline(cornerRadius: 24)
    }

    private var gaugeValue: Double {
        switch test.phase {
        case .download, .upload: test.liveMbps
        case .done: test.downloadMbps ?? 0
        default: 0
        }
    }

    private var readout: String {
        switch test.phase {
        case .latency: NetworkRate.ms(test.pingMs)
        case .download, .upload: test.liveMbps > 0 ? NetworkRate.mbps(test.liveMbps) : "0"
        case .done: NetworkRate.mbps(test.downloadMbps)
        case .idle: "0"
        case .failed: "—"
        }
    }

    private var unit: String { test.phase == .latency ? "ms" : "Mbps" }

    private var caption: String {
        switch test.phase {
        case .idle: "Ready"
        case .latency: "Measuring latency…"
        case .download: "Testing download…"
        case .upload: "Testing upload…"
        case .done: "Download speed"
        case .failed: "Test didn’t finish"
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch test.phase {
        case .done:
            if let verdict = SpeedVerdict(mbps: test.downloadMbps ?? 0) {
                VStack(spacing: 3) {
                    Label(verdict.headline, systemImage: verdict.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.primary)
                    Text(verdict.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        case .failed(let message):
            Label {
                Text(message).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(.red)
            }
            .font(.system(size: 12))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
            .transition(.opacity)
        case .idle:
            Text("Takes about 20 seconds. Pause other downloads for the most accurate result.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .transition(.opacity)
        default:
            Text(runningNote)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .transition(.opacity)
        }
    }

    private var runningNote: String {
        let running = manager.runningCount
        if running > 0 {
            return "\(running) download\(running == 1 ? " is" : "s are") running and will lower the result."
        }
        switch test.phase {
        case .download: return "Pulling data over 6 parallel connections."
        case .upload: return "Sending data over 4 parallel connections."
        default: return "Timing 8 round trips to the nearest Cloudflare server."
        }
    }

    private var actionButton: some View {
        let running = test.isRunning
        let (title, symbol): (String, String) = switch test.phase {
        case .latency, .download, .upload: ("Stop", "stop.fill")
        case .done: ("Test again", "arrow.clockwise")
        case .failed: ("Retry", "arrow.clockwise")
        case .idle: ("Start", "play.fill")
        }
        return Button { running ? test.cancel() : test.start() } label: { buttonLabel(title, symbol) }
            .buttonStyle(SpeedTestButtonStyle(prominent: !running))
            .keyboardShortcut(running ? .cancelAction : .defaultAction)
            .accessibilityLabel(title)
            .help(running ? "Stop the test" : "Measure ping, download and upload speed")
    }

    private func buttonLabel(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 15, weight: .semibold))
            .contentTransition(.symbolEffect(.replace))
            .frame(minWidth: 132)
    }
}

/// Big capsule on Liquid Glass. Prominent = solid accent fill that stays vivid when the window is inactive
/// (system prominent buttons turn grey and read as disabled).
struct SpeedTestButtonStyle: ButtonStyle {
    var prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 26)
            .frame(height: 50)
            .background {
                if prominent {
                    Capsule().fill(LinearGradient(colors: [Color.accentColor.opacity(0.92), Color.accentColor],
                                                  startPoint: .top, endPoint: .bottom))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
                        .shadow(color: Color.accentColor.opacity(0.35), radius: 10, y: 4)
                }
            }
            .contentShape(.capsule)
            .glassEffect(.regular.interactive(), in: .capsule)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// A plain-language reading of a download speed, with a concrete example.
struct SpeedVerdict {
    let headline: String
    let symbol: String
    let detail: String

    init?(mbps: Double) {
        guard mbps > 0 else { return nil }
        switch mbps {
        case 200...: (headline, symbol) = ("Great for 4K streaming and large downloads", "sparkles")
        case 50..<200: (headline, symbol) = ("Great for 4K streaming and video calls", "checkmark.seal.fill")
        case 25..<50: (headline, symbol) = ("Good for HD streaming and everyday downloads", "checkmark.circle.fill")
        case 10..<25: (headline, symbol) = ("Fine for HD video and browsing", "checkmark.circle")
        case 3..<10: (headline, symbol) = ("Okay for browsing and standard video", "tortoise")
        default: (headline, symbol) = ("Slow. Large downloads will take a while", "tortoise.fill")
        }
        // 1 GB = 8,000 megabits.
        let seconds = 8000 / mbps
        detail = "A 1 GB file takes about \(Self.duration(seconds))."
    }

    private static func duration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = seconds >= 120 ? 2 : 1
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : (seconds >= 60 ? [.minute, .second] : [.second])
        return formatter.string(from: max(1, seconds.rounded())) ?? "\(Int(seconds)) seconds"
    }
}
