import Charts
import SwiftUI

/// Health / Screen Time style overview of download history: hero numbers, platforms, media split and a 30-day chart.
struct StatisticsView: View {
    @Environment(HistoryStore.self) private var history

    var body: some View {
        let data = StatisticsData(entries: history.entries)
        Group {
            if history.entries.isEmpty {
                ContentUnavailableView {
                    Label("No statistics yet", systemImage: SidebarItem.statistics.symbol)
                } description: {
                    Text("Finish a few downloads and Root charts what you save, where from, and when.")
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        heroRow(data)
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 16) {
                                PlatformBreakdownCard(slices: data.platforms)
                                MediaSplitCard(data: data).frame(width: 260)
                            }
                            VStack(spacing: 16) {
                                PlatformBreakdownCard(slices: data.platforms)
                                MediaSplitCard(data: data)
                            }
                        }
                        DailyActivityCard(data: data)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    .frame(maxWidth: 980, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .scrollContentBackground(.hidden)
            }
        }

    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Statistics")
                .font(.system(size: 22, weight: .semibold))
            Text("From your download history")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .accessibilityAddTraits(.isHeader)
    }

    private func heroRow(_ data: StatisticsData) -> some View {
        let delta = data.thisWeek - data.lastWeek
        let weekNote = delta == 0 ? "Same as last week" : "\(delta > 0 ? "+" : "−")\(abs(delta)) vs last week"
        return HStack(spacing: 16) {
            StatTile(title: "Files downloaded", symbol: "arrow.down.circle", value: data.totalFiles.formatted(),
                     note: "All time")
            StatTile(title: "Total size", symbol: "internaldrive", value: Format.bytes(data.totalBytes),
                     note: "On disk when saved")
            StatTile(title: "This week", symbol: "calendar", value: data.thisWeek.formatted(), note: weekNote)
        }
    }
}

/// Glass card with a sentence-case title, used by every statistics section.
struct StatCard<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 16)
        .hairline(cornerRadius: 16)
    }
}

/// A single headline number.
struct StatTile: View {
    let title: String
    let symbol: String
    let value: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            Text(note)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 16)
        .hairline(cornerRadius: 16)
        .accessibilityElement(children: .combine)
    }
}

/// Horizontal bars per platform; the axis labels are the brand marks with names.
struct PlatformBreakdownCard: View {
    let slices: [StatisticsData.PlatformSlice]

    private static let rowHeight: CGFloat = 30

    var body: some View {
        StatCard(title: "By platform", subtitle: "Files downloaded from each site") {
            HStack(alignment: .top, spacing: 12) {
                legend
                Chart(slices) { slice in
                    BarMark(x: .value("Downloads", Double(slice.count)), y: .value("Platform", slice.platform.rawValue),
                            height: .fixed(12))
                        .foregroundStyle(Color.accentColor.gradient)
                        .clipShape(.rect(cornerRadii: .init(bottomTrailing: 4, topTrailing: 4)))
                        .annotation(position: .trailing, spacing: 6) {
                            Text(slice.count.formatted())
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel(slice.platform.title)
                        .accessibilityValue("\(slice.count) files, \(Format.bytes(slice.bytes))")
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: slices.map(\.platform.rawValue))
                .chartXScale(domain: 0...Double(max(slices.map(\.count).max() ?? 1, 1)) * 1.12)
                .chartPlotStyle { plot in plot.background(.clear) }
                .frame(height: CGFloat(max(slices.count, 1)) * Self.rowHeight)
            }
        }
    }

    /// The brand-mark legend; each row is exactly one chart band tall so it lines up with its bar.
    private var legend: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(slices) { slice in
                HStack(spacing: 8) {
                    PlatformTile(platform: slice.platform, size: 20)
                    Text(slice.platform.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
                .frame(height: Self.rowHeight)
                .help("\(slice.platform.title): \(slice.count) files, \(Format.bytes(slice.bytes))")
            }
        }
        .frame(width: 128, alignment: .leading)
        .accessibilityHidden(true)
    }
}

/// Video, audio and plain files: a donut with the largest share in the middle and a legend with counts and sizes.
struct MediaSplitCard: View {
    let data: StatisticsData

    private struct Part: Identifiable {
        let name: String
        let count: Int
        let bytes: Int64
        let color: Color
        var id: String { name }
    }

    private var parts: [Part] {
        [Part(name: "Video", count: data.videoCount, bytes: data.videoBytes, color: .accentColor),
         Part(name: "Audio", count: data.audioCount, bytes: data.audioBytes, color: Color.primary.opacity(0.22)),
         Part(name: "Files", count: data.fileCount, bytes: data.fileBytes, color: Color.primary.opacity(0.5))]
    }

    /// The biggest part and its share, for the middle of the donut.
    private var lead: (part: Part, share: Double)? {
        let total = parts.map(\.count).reduce(0, +)
        guard total > 0, let top = parts.max(by: { $0.count < $1.count }) else { return nil }
        return (top, Double(top.count) / Double(total))
    }

    var body: some View {
        StatCard(title: "What you downloaded") {
            VStack(spacing: 16) {
                Chart(parts) { part in
                    SectorMark(angle: .value("Files", part.count), innerRadius: .ratio(0.68), angularInset: 1.5)
                        .cornerRadius(4)
                        .foregroundStyle(part.color)
                        .accessibilityLabel(part.name)
                        .accessibilityValue("\(part.count) files")
                }
                .chartBackground { _ in
                    VStack(spacing: 0) {
                        Text(Format.percent(lead?.share ?? 0))
                            .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                        Text(lead?.part.name.lowercased() ?? "video")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 140, height: 140)
                .frame(maxWidth: .infinity)

                VStack(spacing: 8) {
                    ForEach(parts) { part in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 3).fill(part.color).frame(width: 10, height: 10)
                            Text(part.name).font(.system(size: 12))
                            Spacer()
                            Text("\(part.count.formatted()) · \(Format.bytes(part.bytes))")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

/// Downloads per day for the last 30 days, with a dashed average and hover readout.
struct DailyActivityCard: View {
    let data: StatisticsData
    @State private var hovered: Date?

    var body: some View {
        StatCard(title: "Last 30 days", subtitle: subtitle) {
            Chart {
                ForEach(data.days) { day in
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Downloads", day.count), width: .ratio(0.62))
                        .foregroundStyle(barStyle(for: day))
                        .clipShape(.rect(cornerRadii: .init(topLeading: 3, topTrailing: 3)))
                        .accessibilityLabel(day.date.formatted(date: .abbreviated, time: .omitted))
                        .accessibilityValue("\(day.count) downloads")
                }
                if data.dailyAverage > 0 {
                    RuleMark(y: .value("Average", data.dailyAverage))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, alignment: .leading, spacing: 2) {
                            Text("avg").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                }
                if let hovered, let day = data.days.first(where: { Calendar.current.isDate($0.date, inSameDayAs: hovered) }) {
                    RuleMark(x: .value("Day", day.date, unit: .day))
                        .foregroundStyle(.primary.opacity(0.12))
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            readout(day)
                        }
                }
            }
            .chartXSelection(value: $hovered)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                    AxisGridLine().foregroundStyle(.primary.opacity(0.06))
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(.primary.opacity(0.06))
                    AxisValueLabel()
                }
            }
            .frame(height: 170)
        }
    }

    private var subtitle: String {
        let total = data.days.map(\.count).reduce(0, +)
        return "\(total) download\(total == 1 ? "" : "s") · \(data.dailyAverage.formatted(.number.precision(.fractionLength(1)))) a day on average"
    }

    private func barStyle(for day: StatisticsData.Day) -> Color {
        if let hovered, Calendar.current.isDate(day.date, inSameDayAs: hovered) { return .accentColor }
        return Calendar.current.isDateInToday(day.date) || hovered == nil ? .accentColor : Color.accentColor.opacity(0.45)
    }

    private func readout(_ day: StatisticsData.Day) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(day.count) download\(day.count == 1 ? "" : "s")")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
            Text(day.date.formatted(date: .abbreviated, time: .omitted))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: .rect(cornerRadius: 7))
        .hairline(cornerRadius: 7)
    }
}
