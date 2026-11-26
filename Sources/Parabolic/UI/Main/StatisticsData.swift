import Foundation

/// Everything the Statistics screen shows, computed once from history entries. Pure value type.
struct StatisticsData {
    struct PlatformSlice: Identifiable {
        let platform: Platform
        let count: Int
        let bytes: Int64
        var id: Platform { platform }
    }

    struct Day: Identifiable {
        let date: Date
        let count: Int
        var id: Date { date }
    }

    let totalFiles: Int
    let totalBytes: Int64
    let thisWeek: Int
    let lastWeek: Int
    let videoCount: Int
    let audioCount: Int
    let videoBytes: Int64
    let audioBytes: Int64
    /// Plain files (.apk, .pdf, .zip…), kept out of the video/audio counts.
    let fileCount: Int
    let fileBytes: Int64
    let platforms: [PlatformSlice]
    let days: [Day]

    /// Days in the per-day chart.
    static let dayWindow = 30
    /// Platforms shown individually before the rest fold into "Other Sites".
    static let maxPlatforms = 8

    init(entries: [HistoryEntry], now: Date = Date(), calendar: Calendar = .current) {
        totalFiles = entries.count
        totalBytes = entries.compactMap(\.fileSize).reduce(0, +)

        let today = calendar.startOfDay(for: now)
        let weekStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let previousWeekStart = calendar.date(byAdding: .day, value: -13, to: today) ?? today
        thisWeek = entries.filter { $0.date >= weekStart }.count
        lastWeek = entries.filter { $0.date >= previousWeekStart && $0.date < weekStart }.count

        let files = entries.filter(\.isPlainFile)
        let media = entries.filter { !$0.isPlainFile }
        let audio = media.filter(\.fileType.isAudio)
        let video = media.filter { !$0.fileType.isAudio }
        audioCount = audio.count
        videoCount = video.count
        fileCount = files.count
        audioBytes = audio.compactMap(\.fileSize).reduce(0, +)
        videoBytes = video.compactMap(\.fileSize).reduce(0, +)
        fileBytes = files.compactMap(\.fileSize).reduce(0, +)

        platforms = Self.platformSlices(entries)
        days = Self.dailyCounts(entries, today: today, calendar: calendar)
    }

    var dailyAverage: Double {
        guard !days.isEmpty else { return 0 }
        return Double(days.map(\.count).reduce(0, +)) / Double(days.count)
    }


    private static func platformSlices(_ entries: [HistoryEntry]) -> [PlatformSlice] {
        let grouped = Dictionary(grouping: entries, by: \.platform)
        let sorted = grouped
            .map { PlatformSlice(platform: $0.key, count: $0.value.count, bytes: $0.value.compactMap(\.fileSize).reduce(0, +)) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.platform.title < $1.platform.title }
        let known = sorted.filter { $0.platform != .other }
        let head = Array(known.prefix(maxPlatforms))
        let folded = known.dropFirst(maxPlatforms) + sorted.filter { $0.platform == .other }
        guard !folded.isEmpty else { return head }
        let other = PlatformSlice(platform: .other, count: folded.map(\.count).reduce(0, +),
                                  bytes: folded.map(\.bytes).reduce(0, +))
        return head + [other]
    }

    private static func dailyCounts(_ entries: [HistoryEntry], today: Date, calendar: Calendar) -> [Day] {
        let byDay = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.date) }.mapValues(\.count)
        return (0..<dayWindow).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return Day(date: date, count: byDay[date] ?? 0)
        }
    }
}
