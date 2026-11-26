import SwiftUI

// MARK: - Tokens

/// Design tokens. Use these instead of literals so every surface shares one rhythm.
enum Tokens {
    // Radii are per-component, not uniform.
    static let radiusWindowCard: CGFloat = 20
    static let radiusRow: CGFloat = 14
    static let radiusThumb: CGFloat = 9
    static let radiusControl: CGFloat = 8

    // Spacing scale
    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space5: CGFloat = 24
    static let space6: CGFloat = 32

    // Thumbnail sizes (16:9)
    static let rowThumb = CGSize(width: 112, height: 63)
    static let heroThumb = CGSize(width: 320, height: 180)

    static let motion = Animation.spring(response: 0.32, dampingFraction: 0.86)
    static let quick = Animation.easeOut(duration: 0.18)
}

extension Color {
    /// The app follows the user's macOS accent colour, like first-party apps. No brand hue.
    static let parabolicAccent = Color.accentColor
    static let parabolicAccentDeep = Color.accentColor

    static func status(_ status: DownloadStatus) -> Color {
        switch status {
        case .running: .parabolicAccent
        case .processing: .teal
        case .paused: .yellow
        case .completed: .green
        case .failed: .red
        case .stopped, .queued, .scheduled: .secondary
        }
    }
}

extension DownloadStatus {
    var symbol: String {
        switch self {
        case .queued: "clock"
        case .scheduled: "calendar.badge.clock"
        case .running: "arrow.down.circle.fill"
        case .processing: "gearshape.2.fill"
        case .paused: "pause.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .stopped: "stop.circle"
        }
    }
}

extension MediaFileType {
    var symbol: String { isAudio ? "waveform" : "film" }
}

// MARK: - Formatting

enum Format {
    static func bytes(_ value: Int64?) -> String {
        guard let value, value > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    static func eta(_ seconds: Int?) -> String {
        guard let seconds, seconds >= 0 else { return "" }
        if seconds < 60 { return "\(seconds)s left" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s left" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m left"
    }

    static func duration(_ seconds: Double?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "" }
        return "\(Int((fraction * 100).rounded()))%"
    }
}

// MARK: - Glass surfaces

extension View {
    /// Liquid Glass panel in a rounded rectangle.
    func glassPanel(cornerRadius: CGFloat = Tokens.radiusWindowCard, tint: Color? = nil, interactive: Bool = false) -> some View {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glassEffect(glass, in: .rect(cornerRadius: cornerRadius))
    }

    /// Liquid Glass capsule (pills, chips, URL field).
    func glassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glassEffect(glass, in: .capsule)
    }
}

// MARK: - Components

/// 16:9 artwork with a soft placeholder and optional duration badge.
struct ThumbnailView: View {
    var url: String?
    var size: CGSize = Tokens.rowThumb
    var cornerRadius: CGFloat = Tokens.radiusThumb
    var duration: Double?
    var symbol: String = "play.rectangle"

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    placeholder
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(.rect(cornerRadius: cornerRadius))

            if let text = Format.duration(duration) {
                Text(text)
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.62), in: .rect(cornerRadius: 4))
                    .padding(5)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.white.opacity(0.08)))
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Color.primary.opacity(0.10), Color.primary.opacity(0.04)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: symbol)
                .font(.system(size: min(size.width, size.height) * 0.32, weight: .light))
                .foregroundStyle(.secondary)
        }
    }
}

/// Thin progress capsule; nil progress shows an indeterminate sweep.
struct ProgressCapsule: View {
    var progress: Double?
    var tint: Color = .parabolicAccent
    var height: CGFloat = 5

    @State private var phase: CGFloat = -0.4
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.09))
                if let progress {
                    Capsule()
                        .fill(LinearGradient(colors: [tint.opacity(0.85), tint], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(height, proxy.size.width * min(1, max(0, progress))))
                        .animation(Tokens.quick, value: progress)
                } else {
                    Capsule()
                        .fill(tint.opacity(0.75))
                        .frame(width: proxy.size.width * 0.32)
                        .offset(x: proxy.size.width * phase)
                        .onAppear {
                            guard !reduceMotion else { phase = 0.34; return }
                            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { phase = 0.72 }
                        }
                }
            }
            .clipShape(.capsule)
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(progress.map { Format.percent($0) } ?? "In progress")
    }
}

/// Minimal speed sparkline (area + line), normalised to its own max.
struct Sparkline: View {
    var samples: [Double]
    var tint: Color = .parabolicAccent

    var body: some View {
        GeometryReader { proxy in
            let points = normalized(in: proxy.size)
            if points.count > 1 {
                ZStack {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: proxy.size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: points.last!.x, y: proxy.size.height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
                    Path { path in
                        path.move(to: points[0])
                        points.dropFirst().forEach { path.addLine(to: $0) }
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func normalized(in size: CGSize) -> [CGPoint] {
        guard samples.count > 1 else { return [] }
        let peak = max(samples.max() ?? 1, 1)
        let step = size.width / CGFloat(samples.count - 1)
        return samples.enumerated().map { index, value in
            CGPoint(x: CGFloat(index) * step, y: size.height - CGFloat(value / peak) * (size.height - 2) - 1)
        }
    }
}

/// Small glass chip with an SF Symbol and label, used for metadata and filters.
struct Chip: View {
    var text: String
    var symbol: String?
    var tint: Color?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(tint ?? .secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background((tint ?? .primary).opacity(0.1), in: .capsule)
    }
}

/// Grouped settings-style card with a sentence-case caption above it (HIG inset grouped list).
struct GroupCard<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
            }
            VStack(spacing: 0) { content }
                .padding(.vertical, 4)
                .glassPanel(cornerRadius: Tokens.radiusRow)
            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One row inside a GroupCard: label on the left, control on the right, inset divider below.
struct GroupRow<Trailing: View>: View {
    var title: String
    var subtitle: String?
    var symbol: String?
    var showsDivider = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.parabolicAccent)
                        .frame(width: 20)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13))
                    if let subtitle {
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                trailing
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            if showsDivider {
                Divider().padding(.leading, symbol == nil ? 14 : 44).padding(.trailing, 14)
            }
        }
    }
}
