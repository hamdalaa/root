import Foundation

/// One interpreted line of yt-dlp output.
enum ProgressEvent: Equatable, Sendable {
    /// fraction is nil when the total size is unknown.
    case downloading(fraction: Double?, downloaded: Int64, total: Int64?, speed: Double?, eta: Int?)
    case processing(String)
    case finalFile(String)
    case sleeping(Double)
    case error(String)
    case log
}

enum ProgressParser {
    static func parse(_ line: String) -> ProgressEvent {
        if line.hasPrefix(ArgumentBuilder.progressPrefix) {
            return parseTemplate(line)
        }
        if line.hasPrefix(ArgumentBuilder.filePrefix) {
            return .finalFile(String(line.dropFirst(ArgumentBuilder.filePrefix.count)))
        }
        if let range = line.range(of: "[NOTICE] Download complete: ") {
            let path = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            // Torrent metadata fetched into memory isn't the user's file.
            return path.hasPrefix("[MEMORY]") ? .log : .finalFile(path)
        }
        if let range = line.range(of: "[ERROR] ") {
            let message = String(line[range.upperBound...])
            return .error(message.replacingOccurrences(of: #"CUID#\d+ - "#, with: "", options: .regularExpression))
        }
        if line.hasPrefix("ERROR:") {
            return .error(String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces))
        }
        if line.hasPrefix("[download] Sleeping ") {
            let rest = line.dropFirst("[download] Sleeping ".count)
            let seconds = Double(rest.prefix { $0.isNumber || $0 == "." }) ?? 0
            return .sleeping(seconds)
        }
        if let aria = parseAria(line) { return aria }
        for (tag, label) in processingTags where line.hasPrefix(tag) {
            return .processing(label)
        }
        return .log
    }

    private static let processingTags: [(String, String)] = [
        ("[Merger]", "Merging video and audio…"),
        ("[ExtractAudio]", "Converting audio…"),
        ("[VideoConvertor]", "Converting video…"),
        ("[VideoRemuxer]", "Remuxing…"),
        ("[EmbedThumbnail]", "Embedding artwork…"),
        ("[EmbedSubtitle]", "Embedding subtitles…"),
        ("[Metadata]", "Writing metadata…"),
        ("[SponsorBlock]", "Removing sponsor segments…"),
        ("[ModifyChapters]", "Cutting segments…"),
        ("[SplitChapters]", "Splitting chapters…"),
        ("[FixupM3u8]", "Fixing stream container…"),
        ("[FixupM4a]", "Fixing audio container…"),
        ("[ThumbnailsConvertor]", "Converting artwork…"),
        ("[SubtitlesConvertor]", "Converting subtitles…"),
    ]

    /// `[PB];status;downloaded;total;estimate;speed;eta` — fields may be "NA".
    static func parseTemplate(_ line: String) -> ProgressEvent {
        let fields = line.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 7 else { return .log }
        let status = fields[1]
        if status == "finished" { return .processing("Finishing…") }
        let downloaded = Int64(Double(fields[2]) ?? 0)
        let total = Double(fields[3]) ?? Double(fields[4])
        let speed = Double(fields[5])
        let eta = Double(fields[6]).map { Int($0) }
        let fraction = total.flatMap { $0 > 0 ? min(1, Double(downloaded) / $0) : nil }
        return .downloading(fraction: fraction, downloaded: downloaded, total: total.map { Int64($0) }, speed: speed, eta: eta)
    }

    /// aria2c summary: `[#2089b0 400.0KiB/33.2MiB(1%) CN:1 DL:115.7KiB ETA:4m51s]`
    static func parseAria(_ line: String) -> ProgressEvent? {
        guard line.hasPrefix("[#"), let slash = line.firstIndex(of: "/"), let space = line.firstIndex(of: " ") else { return nil }
        let doneText = String(line[line.index(after: space)..<slash])
        guard let open = line.firstIndex(of: "("), let pct = line.firstIndex(of: "%") else { return nil }
        let totalText = String(line[line.index(after: slash)..<open])
        let percent = Double(line[line.index(after: open)..<pct]) ?? 0
        var speed: Double?
        if let dl = line.range(of: "DL:") {
            let tail = line[dl.upperBound...].prefix { $0 != " " && $0 != "]" }
            speed = bytes(String(tail))
        }
        var eta: Int?
        if let range = line.range(of: "ETA:") {
            eta = seconds(String(line[range.upperBound...].prefix { $0 != "]" && $0 != " " }))
        }
        return .downloading(fraction: percent / 100, downloaded: Int64(bytes(doneText) ?? 0),
                            total: bytes(totalText).map { Int64($0) }, speed: speed, eta: eta)
    }

    static func bytes(_ text: String) -> Double? {
        let units: [(String, Double)] = [("GiB", 1_073_741_824), ("MiB", 1_048_576), ("KiB", 1024), ("B", 1)]
        for (suffix, scale) in units where text.hasSuffix(suffix) {
            return Double(text.dropLast(suffix.count)).map { $0 * scale }
        }
        return Double(text)
    }

    static func seconds(_ text: String) -> Int? {
        var total = 0, number = ""
        for char in text {
            if char.isNumber { number.append(char); continue }
            guard let value = Int(number) else { return nil }
            switch char {
            case "h": total += value * 3600
            case "m": total += value * 60
            case "s": total += value
            default: return nil
            }
            number = ""
        }
        return total
    }
}
