import Foundation

enum DiscoveryError: LocalizedError {
    case toolMissing
    case invalidURL
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .toolMissing: "yt-dlp isn't installed. Install it from Settings → yt-dlp."
        case .invalidURL: "That doesn't look like a link."
        case .failed(let message): message
        }
    }
}

/// Asks yt-dlp what's behind a URL: a single media item (with formats) or a playlist (flat entries).
enum Discovery {
    static func discover(url: String, prefs: Preferences, tools: ToolPaths, credential: ResolvedCredential?,
                         singleVideo: Bool = false) async throws -> MediaInfo {
        guard let normalized = normalizeURL(url) else { throw DiscoveryError.invalidURL }
        switch EngineRouter.engine(for: normalized) {
        case .torrent: return DirectProbe.torrent(normalized)
        case .direct: return try await DirectProbe.probe(normalized)
        case .media: break
        }
        guard let ytdlp = tools.ytdlp else { throw DiscoveryError.toolMissing }
        let platform = Platform.detect(url: normalized)
        if platform == .spotify || platform == .deezer {
            return try await MusicLinkResolver.resolve(normalized)
        }
        var args = ArgumentBuilder.discovery(url: normalized, prefs: prefs, tools: tools, credential: credential)
        if singleVideo { args.insert("--no-playlist", at: 0) }
        let output = try await ProcessRunner.capture(executable: ytdlp, arguments: args, environment: ["PATH": tools.childPATH])
        try Task.checkCancellation()
        let json = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = json.data(using: .utf8), !json.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // Not a media page yt-dlp knows: treat it as a plain file if the server serves one.
            if output.stderr.contains("Unsupported URL"), let file = try? await DirectProbe.probe(normalized),
               let type = file.directFile?.contentType?.lowercased(), !type.hasPrefix("text/html") {
                return file
            }
            throw DiscoveryError.failed(cleanError(output.stderr) ?? "yt-dlp couldn't read this link.")
        }
        let info = parse(root, sourceURL: normalized)
        // yt-dlp's catch-all "generic" extractor also claims raw files (installers, binaries).
        // If what it found isn't audio/video, ask the server and hand it to the file engine.
        if info.meta.extractor?.lowercased() == "generic", !info.isPlaylist,
           info.formats.allSatisfy({ !$0.hasVideo && !$0.hasAudio || $0.ext == "unknown_video" }),
           let file = try? await DirectProbe.probe(normalized),
           let type = file.directFile?.contentType?.lowercased(),
           !type.hasPrefix("video/"), !type.hasPrefix("audio/"), !type.hasPrefix("text/html") {
            return file
        }
        return info
    }

    /// Site search through yt-dlp's search extractors (e.g. `ytsearch20:query`).
    static func search(_ query: String, source: SearchSource, limit: Int = 24, prefs: Preferences, tools: ToolPaths) async throws -> [PlaylistEntry] {
        guard let ytdlp = tools.ytdlp else { throw DiscoveryError.toolMissing }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let args = ArgumentBuilder.discovery(url: "\(source.prefix)\(limit):\(trimmed)", prefs: prefs, tools: tools, credential: nil)
        let output = try await ProcessRunner.capture(executable: ytdlp, arguments: args, environment: ["PATH": tools.childPATH])
        try Task.checkCancellation()
        guard let data = output.stdout.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DiscoveryError.failed(cleanError(output.stderr) ?? "Search failed.")
        }
        return parse(root, sourceURL: "").entries.map { entry in
            var entry = entry
            // YouTube search entries give a bare id as url on some versions.
            if source == .youtube, !entry.url.hasPrefix("http") { entry.url = "https://www.youtube.com/watch?v=\(entry.url)" }
            return entry
        }
    }

    static func normalizeURL(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.lowercased().hasPrefix("magnet:?") { return text }
        // Local .torrent files (Open Torrent File…, drag & drop, Finder) go straight to aria2 as a path.
        // Checked before the no-spaces rule: "/Users/me/My Show.torrent" is a valid path.
        if text.hasPrefix("file://") { text = URL(string: text)?.path ?? text }
        if text.hasPrefix("/"), text.lowercased().hasSuffix(".torrent"), FileManager.default.fileExists(atPath: text) { return text }
        guard !text.contains(" ") else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return url.absoluteString
    }

    /// Pulls the human part out of yt-dlp's stderr ("ERROR: [youtube] xyz: Video unavailable").
    static func cleanError(_ stderr: String) -> String? {
        let errors = stderr.split(separator: "\n").filter { $0.hasPrefix("ERROR:") }
        guard let last = errors.last else { return nil }
        var message = String(last.dropFirst("ERROR:".count)).trimmingCharacters(in: .whitespaces)
        // Drop "[extractor] id: " prefix.
        if message.hasPrefix("["), let close = message.firstIndex(of: "]") {
            message = String(message[message.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            if let colon = message.firstIndex(of: ":"), message[..<colon].count < 40, !message[..<colon].contains(" ") {
                message = String(message[message.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return message.isEmpty ? nil : message
    }

    static func parse(_ root: [String: Any], sourceURL: String) -> MediaInfo {
        let meta = MediaMeta(
            title: (root["title"] as? String) ?? (root["id"] as? String) ?? sourceURL,
            uploader: (root["uploader"] as? String) ?? (root["channel"] as? String) ?? (root["playlist_uploader"] as? String),
            duration: number(root["duration"]),
            thumbnailURL: bestThumbnail(root),
            webpageURL: (root["webpage_url"] as? String) ?? sourceURL,
            extractor: (root["extractor_key"] as? String) ?? (root["extractor"] as? String),
            isLive: (root["is_live"] as? Bool) ?? ((root["live_status"] as? String) == "is_live")
        )
        var info = MediaInfo(meta: meta)

        if (root["_type"] as? String) == "playlist", let entries = root["entries"] as? [[String: Any]] {
            info.entries = entries.enumerated().compactMap { offset, entry in
                guard let url = (entry["url"] as? String) ?? (entry["webpage_url"] as? String) else { return nil }
                let id = (entry["id"] as? String) ?? "\(offset)"
                return PlaylistEntry(
                    id: "\(offset)-\(id)",
                    index: (entry["playlist_index"] as? Int) ?? offset + 1,
                    url: url,
                    title: (entry["title"] as? String) ?? id,
                    duration: number(entry["duration"]),
                    thumbnailURL: bestThumbnail(entry),
                    uploader: (entry["uploader"] as? String) ?? (entry["channel"] as? String),
                    viewCount: entry["view_count"] as? Int)
            }
            return info
        }

        if let formats = root["formats"] as? [[String: Any]] {
            info.formats = formats.compactMap { f in
                guard let id = f["format_id"] as? String else { return nil }
                // Storyboards / images are not downloadable media.
                if (f["ext"] as? String) == "mhtml" || (f["format_note"] as? String) == "storyboard" { return nil }
                return MediaFormat(
                    id: id,
                    ext: (f["ext"] as? String) ?? "?",
                    width: f["width"] as? Int,
                    height: f["height"] as? Int,
                    fps: number(f["fps"]),
                    vcodec: f["vcodec"] as? String,
                    acodec: f["acodec"] as? String,
                    abr: number(f["abr"]),
                    tbr: number(f["tbr"]),
                    filesize: (f["filesize"] as? Int64) ?? (f["filesize"] as? Int).map(Int64.init) ?? number(f["filesize_approx"]).map { Int64($0) },
                    note: f["format_note"] as? String)
            }
        }
        if let subs = root["subtitles"] as? [String: Any] {
            info.subtitleLanguages = subs.keys.filter { $0 != "live_chat" }.sorted()
        }
        if let auto = root["automatic_captions"] as? [String: Any] {
            // YouTube lists ~150 translated tracks; keep originals ("-orig") and plain codes.
            info.autoCaptionLanguages = auto.keys.filter { !$0.contains("-") || $0.hasSuffix("-orig") }.sorted()
        }
        info.chapterCount = (root["chapters"] as? [Any])?.count ?? 0
        return info
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: d
        case let i as Int: Double(i)
        case let n as NSNumber: n.doubleValue
        default: nil
        }
    }

    private static func bestThumbnail(_ dict: [String: Any]) -> String? {
        if let thumb = dict["thumbnail"] as? String { return thumb }
        guard let thumbs = dict["thumbnails"] as? [[String: Any]], !thumbs.isEmpty else { return nil }
        // Pick the widest under ~1280px; flat playlist entries often lack sizes, so fall back to last.
        let sized = thumbs.filter { ($0["width"] as? Int ?? 0) > 0 && ($0["width"] as? Int ?? 0) <= 1280 }
        let pick = sized.max { ($0["width"] as? Int ?? 0) < ($1["width"] as? Int ?? 0) } ?? thumbs.last
        return pick?["url"] as? String
    }
}
