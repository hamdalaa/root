import SwiftUI

// MARK: - Phase steps

/// "Latency · Download · Upload" with the current step lit and finished steps ticked.
struct SpeedPhaseSteps: View {
    let phase: SpeedTest.Phase

    private enum Step: Int, CaseIterable {
        case latency, download, upload
        var title: String { ["Latency", "Download", "Upload"][rawValue] }
        var symbol: String { ["timer", "arrow.down", "arrow.up"][rawValue] }
    }

    private var current: Int? {
        switch phase {
        case .latency: 0
        case .download: 1
        case .upload: 2
        case .done: 3
        case .idle, .failed: nil
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.rawValue) { step in
                let state = state(of: step)
                HStack(spacing: 4) {
                    Image(systemName: state == .done ? "checkmark" : step.symbol)
                        .font(.system(size: 9, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))
                    Text(step.title)
                        .font(.system(size: 11, weight: state == .active ? .semibold : .medium))
                }
                .foregroundStyle(state == .active ? AnyShapeStyle(Color.accentColor)
                                 : state == .done ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(Capsule().fill(state == .active ? Color.accentColor.opacity(0.14) : .primary.opacity(0.04)))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private enum StepState { case pending, active, done }

    private func state(of step: Step) -> StepState {
        guard let current else { return .pending }
        if step.rawValue < current { return .done }
        return step.rawValue == current ? .active : .pending
    }
}

// MARK: - Result tiles

/// Ping, jitter, download and upload. The tile being measured shows its live value.
struct SpeedResultTiles: View {
    @Environment(SpeedTest.self) private var test

    var body: some View {
        let tiles = [
            tile("Ping", "timer", NetworkRate.ms(test.pingMs), "ms", test.pingMs ?? 0, active: test.phase == .latency),
            tile("Jitter", "waveform.path", NetworkRate.ms(test.jitterMs), "ms", test.jitterMs ?? 0, active: test.phase == .latency),
            tile("Download", "arrow.down.circle", NetworkRate.mbps(downloadValue), "Mbps", downloadValue ?? 0,
                 active: test.phase == .download, tint: NetworkRate.downloadTint),
            tile("Upload", "arrow.up.circle", NetworkRate.mbps(uploadValue), "Mbps", uploadValue ?? 0,
                 active: test.phase == .upload, tint: NetworkRate.uploadTint),
        ]
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { ForEach(0..<4, id: \.self) { tiles[$0] } }
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow { tiles[0]; tiles[1] }
                GridRow { tiles[2]; tiles[3] }
            }
        }
    }

    private var downloadValue: Double? { test.phase == .download ? test.liveMbps : test.downloadMbps }
    private var uploadValue: Double? { test.phase == .upload ? test.liveMbps : test.uploadMbps }

    private func tile(_ title: String, _ symbol: String, _ value: String, _ unit: String, _ number: Double,
                      active: Bool, tint: Color = .accentColor) -> SpeedResultTile {
        SpeedResultTile(title: title, symbol: symbol, value: value, unit: unit, number: number, isActive: active, tint: tint)
    }
}

struct SpeedResultTile: View {
    let title: String
    let symbol: String
    let value: String
    let unit: String
    let number: Double
    let isActive: Bool
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .foregroundStyle(isActive ? tint : .secondary)
                Text(title)
                Spacer(minLength: 0)
                if isActive {
                    ProgressView().controlSize(.mini)
                        .transition(.opacity)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(value == "—" ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    .contentTransition(.numericText(value: number))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(unit)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 16, tint: isActive ? tint.opacity(0.1) : nil)
        .hairline(cornerRadius: 16)
        .animation(.snappy, value: value)
        .animation(Tokens.quick, value: isActive)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value == "—" ? "Not measured" : "\(value) \(unit)")
    }
}

// MARK: - Live network

/// System-wide throughput right now, with a minute of history.
struct LiveNetworkCard: View {
    @Environment(NetworkMonitor.self) private var network

    var body: some View {
        StatCard(title: "Live network", subtitle: "Everything this Mac is sending and receiving") {
            VStack(spacing: 14) {
                row("Download", "arrow.down", network.downloadBytesPerSecond, network.downloadHistory, NetworkRate.downloadTint)
                Divider()
                row("Upload", "arrow.up", network.uploadBytesPerSecond, network.uploadHistory, NetworkRate.uploadTint)
            }
        }
        .frame(minWidth: 280)
    }

    private func row(_ title: String, _ symbol: String, _ value: Double, _ samples: [Double], _ tint: Color) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(NetworkRate.text(value))
                    .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText(value: value))
                    .animation(.snappy, value: value)
            }
            .frame(width: 104, alignment: .leading)
            Sparkline(samples: samples.count > 1 ? samples : [0, 0], tint: tint)
                .frame(height: 38)
                .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(NetworkRate.text(value))")
    }
}

// MARK: - History

/// Past results, newest first.
struct SpeedHistoryCard: View {
    @Environment(SpeedTest.self) private var test

    private static let visible = 8

    private var subtitle: String {
        let shown = min(test.history.count, Self.visible)
        switch shown {
        case 0: return "Your results collect here"
        case 1: return "Your last test"
        default: return "Your last \(shown) tests"
        }
    }

    var body: some View {
        StatCard(title: "History", subtitle: subtitle) {
            if test.history.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Run a test to start a history of your connection.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 90)
            } else {
                Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow {
                        Text("Date").gridColumnAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                        Text("Download")
                        Text("Upload")
                        Text("Ping")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    ForEach(test.history.prefix(Self.visible)) { result in
                        Divider().gridCellUnsizedAxes(.horizontal)
                        GridRow {
                            Text(result.date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                                .foregroundStyle(.secondary)
                            value(NetworkRate.mbps(result.downloadMbps), "Mbps")
                            value(NetworkRate.mbps(result.uploadMbps), "Mbps")
                            value(NetworkRate.ms(result.pingMs), "ms")
                        }
                        .font(.system(size: 12).monospacedDigit())
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .frame(minWidth: 320)
        .animation(Tokens.motion, value: test.history.map(\.id))
    }

    private func value(_ number: String, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(number).fontWeight(.medium)
            Text(unit).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }
}
