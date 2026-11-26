import SwiftUI

/// The one big element: memory used, the pressure state, a plain verdict and the composition bar.
struct MemoryHero: View {
    let snapshot: MemorySnapshot
    private var monitor: MemoryMonitor { .shared }

    var body: some View {
        let b = snapshot.breakdown
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Memory used")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(MemoryFormat.bytes(b.used))
                            .font(.system(size: 46, weight: .semibold, design: .rounded).monospacedDigit())
                            .contentTransition(.numericText(value: Double(b.used)))
                            .animation(.snappy, value: b.used)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text("of \(MemoryFormat.bytes(b.total))")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Memory used")
                .accessibilityValue("\(MemoryFormat.bytes(b.used)) of \(MemoryFormat.bytes(b.total))")
                Spacer(minLength: 0)
                MemoryPressureBadge(level: snapshot.pressure, percent: snapshot.pressurePercent)
            }

            if let verdict = monitor.verdict { verdictBlock(verdict) }

            VStack(alignment: .leading, spacing: 12) {
                MemoryCompositionBar(breakdown: b)
                MemoryCompositionLegend(breakdown: b)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 24)
        .hairline(cornerRadius: 24)
    }

    private func verdictBlock(_ verdict: MemoryVerdict) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: MemoryStyle.symbol(verdict.severity))
                .font(.system(size: 22, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(MemoryStyle.color(verdict.severity))
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verdict.headline)
                    .font(.system(size: 15, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(verdict.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if verdict.severity == .warning || verdict.severity == .critical, let top = monitor.suggestions.first {
                Button { monitor.quit(top) } label: {
                    Text("Quit \(top.name)").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .help("Ask \(top.name) to quit. It will offer to save unsaved work.")
            }
        }
        .padding(14)
        .background(MemoryStyle.color(verdict.severity).opacity(verdict.severity == .ok ? 0.07 : 0.11),
                    in: .rect(cornerRadius: 16, style: .continuous))
        .animation(Tokens.quick, value: verdict)
    }
}

// MARK: - Pressure badge

struct MemoryPressureBadge: View {
    let level: MemoryPressureLevel?
    let percent: Double?

    var body: some View {
        let color = MemoryStyle.color(level)
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(level.map { "Pressure \($0.title.lowercased())" } ?? "Pressure unavailable")
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(color.opacity(0.14), in: .capsule)
            if let percent {
                Text("\(Int(percent.rounded()))% pressure")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Memory pressure")
        .accessibilityValue([level?.title ?? "unavailable", percent.map { "\(Int($0.rounded())) percent" }]
            .compactMap { $0 }.joined(separator: ", "))
        .help("How hard macOS is working to keep memory available. Green is normal; yellow means it’s compressing heavily; red means apps are being slowed or paused.")
    }
}

// MARK: - Composition

/// One category of the bar and legend.
private struct MemorySegment: Identifiable {
    let name: String
    let bytes: UInt64
    let style: AnyShapeStyle
    let explanation: String
    var id: String { name }
}

private func memorySegments(_ b: MemoryBreakdown) -> (used: [MemorySegment], available: [MemorySegment], other: MemorySegment?) {
    let used = [
        MemorySegment(name: "App", bytes: b.app, style: AnyShapeStyle(Color.accentColor),
                      explanation: "Memory apps and their helpers are holding right now."),
        MemorySegment(name: "Wired", bytes: b.wired, style: AnyShapeStyle(Color.accentColor.opacity(0.62)),
                      explanation: "Memory the system has locked in place. It can’t be compressed or moved to disk."),
        MemorySegment(name: "Compressed", bytes: b.compressed, style: AnyShapeStyle(Color.accentColor.opacity(0.36)),
                      explanation: b.compressionRatio.map {
                          "Memory macOS squeezed to make room: \(MemoryFormat.bytes(b.compressedOriginal)) of data stored in \(MemoryFormat.bytes(b.compressed)) (\($0.formatted(.number.precision(.fractionLength(1))))×)."
                      } ?? "Memory macOS squeezed to make room."),
    ]
    let available = [
        MemorySegment(name: "Cached files", bytes: b.cached, style: AnyShapeStyle(Color.primary.opacity(0.2)),
                      explanation: "Recently used files kept in memory. macOS hands this back the moment an app needs it."),
        MemorySegment(name: "Free", bytes: b.free, style: AnyShapeStyle(Color.primary.opacity(0.07)),
                      explanation: "Memory holding nothing. A low number is normal: macOS puts spare memory to work as cache."),
    ]
    let other = b.other > 0 && b.fraction(b.other) >= 0.003
        ? MemorySegment(name: "Other", bytes: b.other, style: AnyShapeStyle(Color.primary.opacity(0.12)),
                        explanation: "Installed memory macOS’s counters don’t assign to a category, such as firmware and graphics reservations.")
        : nil
    return (used, available, other)
}

/// A big segmented bar: used categories in accent tones, reclaimable memory in neutral tones.
struct MemoryCompositionBar: View {
    let breakdown: MemoryBreakdown
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: String?

    private static let height: CGFloat = 30
    private static let gap: CGFloat = 2

    var body: some View {
        let parts = memorySegments(breakdown)
        let all = parts.used + [parts.other].compactMap { $0 } + parts.available
        GeometryReader { proxy in
            let visible = all.filter { $0.bytes > 0 }
            let usable = max(0, proxy.size.width - Self.gap * CGFloat(max(visible.count - 1, 0)))
            HStack(spacing: Self.gap) {
                ForEach(visible) { segment in
                    Rectangle()
                        .fill(segment.style)
                        .frame(width: max(2, usable * breakdown.fraction(segment.bytes)))
                        .opacity(hovered == nil || hovered == segment.id ? 1 : 0.45)
                        .onHover { inside in
                            if inside { hovered = segment.id } else if hovered == segment.id { hovered = nil }
                        }
                        .help("\(segment.name): \(MemoryFormat.bytes(segment.bytes)). \(segment.explanation)")
                }
            }
            .frame(width: proxy.size.width, alignment: .leading)
            .clipShape(.rect(cornerRadius: 9, style: .continuous))
        }
        .frame(height: Self.height)
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .animation(reduceMotion ? nil : .smooth(duration: 0.6), value: breakdown)
        .animation(Tokens.quick, value: hovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Memory composition")
        .accessibilityValue(all.map { "\($0.name) \(MemoryFormat.bytes($0.bytes))" }.joined(separator: ", "))
    }
}

/// Two labelled columns under the bar: what's used, and what macOS can hand out right away.
struct MemoryCompositionLegend: View {
    let breakdown: MemoryBreakdown

    var body: some View {
        let parts = memorySegments(breakdown)
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 28) { columns(parts) }
            VStack(alignment: .leading, spacing: 14) { columns(parts) }
        }
    }

    @ViewBuilder
    private func columns(_ parts: (used: [MemorySegment], available: [MemorySegment], other: MemorySegment?)) -> some View {
        column("Used", total: breakdown.used, parts.used)
        column("Available", total: breakdown.available, parts.available)
        if let other = parts.other { column("Not counted", total: nil, [other]) }
    }

    private func column(_ title: String, total: UInt64?, _ segments: [MemorySegment]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                if let total {
                    Text(MemoryFormat.bytes(total)).font(.system(size: 11, weight: .semibold).monospacedDigit())
                }
            }
            HStack(spacing: 16) {
                ForEach(segments) { segment in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(segment.style)
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.primary.opacity(0.1)))
                            .frame(width: 10, height: 10)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                        VStack(alignment: .leading, spacing: 0) {
                            Text(segment.name).font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(MemoryFormat.bytes(segment.bytes))
                                .font(.system(size: 13, weight: .medium).monospacedDigit())
                                .contentTransition(.numericText(value: Double(segment.bytes)))
                        }
                    }
                    .help(segment.explanation)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint(segment.explanation)
                }
            }
        }
    }
}
