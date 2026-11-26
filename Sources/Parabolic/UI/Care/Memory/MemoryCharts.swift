import Charts
import SwiftUI

/// Memory pressure for the last five minutes, one bar per second, coloured by the kernel's pressure level
/// (the same reading as Activity Monitor's graph).
struct MemoryPressureHistoryCard: View {
    private var monitor: MemoryMonitor { .shared }
    @State private var selected: Date?

    var body: some View {
        let points = monitor.history.filter { $0.pressurePercent != nil }
        StatCard(title: "Memory pressure", subtitle: subtitle(points)) {
            if points.count < 2 {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Collecting a few seconds of readings…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                chart(points)
            }
        }
        .frame(minWidth: 340)
    }

    private func subtitle(_ points: [MemoryMonitor.HistoryPoint]) -> String {
        guard let first = points.first?.date, let last = points.last?.date else {
            return "Live, while this screen is open"
        }
        let span = Int(last.timeIntervalSince(first).rounded())
        return span >= 60 ? "Last \(span / 60) min\(span >= 120 ? "s" : "") · while this screen is open"
            : "Last \(span) seconds · while this screen is open"
    }

    private func chart(_ points: [MemoryMonitor.HistoryPoint]) -> some View {
        let end = (points.last?.date ?? Date()).addingTimeInterval(1)
        let start = end.addingTimeInterval(-MemoryMonitor.historyWindow)
        let selectedPoint = selected.flatMap { date in points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) } }
        return Chart {
            ForEach(points) { point in
                BarMark(x: .value("Time", point.date, unit: .second),
                        y: .value("Pressure", point.pressurePercent ?? 0))
                    .foregroundStyle(MemoryStyle.color(point.level).opacity(selectedPoint == nil || selectedPoint?.id == point.id ? 0.9 : 0.4))
            }
            if let selectedPoint {
                RuleMark(x: .value("Time", selectedPoint.date, unit: .second))
                    .foregroundStyle(.primary.opacity(0.15))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        readout(selectedPoint)
                    }
            }
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: 0...100)
        .chartXSelection(value: $selected)
        .chartXAxis {
            AxisMarks(values: .stride(by: .minute, count: 1)) { _ in
                AxisGridLine().foregroundStyle(.primary.opacity(0.06))
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, 50, 100]) { value in
                AxisGridLine().foregroundStyle(.primary.opacity(0.06))
                AxisValueLabel { if let v = value.as(Int.self) { Text("\(v)%") } }
            }
        }
        .frame(height: 150)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Memory pressure history")
        .accessibilityValue(accessibilitySummary(points))
    }

    private func readout(_ point: MemoryMonitor.HistoryPoint) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(Int((point.pressurePercent ?? 0).rounded()))% · \(point.level?.title ?? "Unknown")")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
            Text("\(MemoryFormat.bytes(point.used)) used · \(point.date.formatted(date: .omitted, time: .standard))")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: .rect(cornerRadius: 7))
        .hairline(cornerRadius: 7)
    }

    private func accessibilitySummary(_ points: [MemoryMonitor.HistoryPoint]) -> String {
        let values = points.compactMap(\.pressurePercent)
        guard let now = values.last, let low = values.min(), let high = values.max() else { return "No data" }
        return "Now \(Int(now.rounded())) percent. Range \(Int(low.rounded())) to \(Int(high.rounded())) percent."
    }
}

/// Swap and compression: the two things macOS does when RAM runs short.
struct MemorySwapCard: View {
    let snapshot: MemorySnapshot
    private var monitor: MemoryMonitor { .shared }

    var body: some View {
        StatCard(title: "Swap and compression", subtitle: "What macOS does when RAM runs short") {
            VStack(alignment: .leading, spacing: 14) {
                swapSection
                Divider()
                activity
                Divider()
                compression
            }
        }
    }

    @ViewBuilder private var swapSection: some View {
        if let swap = snapshot.swap {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Swap used").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Text(swap.total > 0 ? "of \(MemoryFormat.bytes(swap.total)) swap file" : "No swap file")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Text(swap.used > 0 ? MemoryFormat.bytes(swap.used) : "None")
                    .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText(value: Double(swap.used)))
                    .animation(.snappy, value: swap.used)
                MemorySwapSparkline(points: monitor.history)
                    .frame(height: 30)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Swap used")
            .accessibilityValue(swap.used > 0 ? "\(MemoryFormat.bytes(swap.used)) of \(MemoryFormat.bytes(swap.total))" : "None")
        } else {
            Label("macOS didn’t report swap usage.", systemImage: "questionmark.circle")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var activity: some View {
        HStack(spacing: 18) {
            rate("Swapping in", "arrow.down.to.line", monitor.swapInRate)
            rate("Swapping out", "arrow.up.to.line", monitor.swapOutRate)
        }
        .help("How fast memory is moving between RAM and the swap file on disk right now. Sustained swapping is what makes a Mac feel slow.")
    }

    private func rate(_ title: String, _ symbol: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value.map { $0 >= 1 ? MemoryFormat.bytes(UInt64($0)) + "/s" : "Idle" } ?? "—")
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundStyle(value == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var compression: some View {
        let b = snapshot.breakdown
        return VStack(alignment: .leading, spacing: 2) {
            Text("Compressed").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            if let ratio = b.compressionRatio {
                Text("\(MemoryFormat.bytes(b.compressedOriginal)) in \(MemoryFormat.bytes(b.compressed))")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                Text("macOS is fitting \(ratio.formatted(.number.precision(.fractionLength(1)))) bytes of data into each byte of RAM it compresses.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Nothing compressed").font(.system(size: 14, weight: .semibold))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Swap used over the visible history, normalised to its own range so small changes show.
private struct MemorySwapSparkline: View {
    let points: [MemoryMonitor.HistoryPoint]

    var body: some View {
        let values = points.compactMap(\.swapUsed).map(Double.init)
        let low = values.min() ?? 0
        Sparkline(samples: values.count > 1 ? values.map { $0 - low } : [0, 0], tint: .accentColor)
    }
}
