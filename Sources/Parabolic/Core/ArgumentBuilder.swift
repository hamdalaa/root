import Foundation

/// Login handed to yt-dlp. Username empty + password set means a video password.
struct ResolvedCredential: Sendable {
    var username: String
    var password: String
}

/// Pure translation of options + preferences into yt-dlp arguments. No I/O, fully testable.
enum ArgumentBuilder {
    static let progressPrefix = "[PB]"
    static let filePrefix = "[PBFILE]"

    static func discovery(url: String, prefs: Preferences, tools: ToolPaths, credential: ResolvedCredential?) -> [String] {
        var args = [
            url,
            "--ignore-config",
            "--dump-single-json",
            "--flat-playlist",
            "--skip-download",
            "--ignore-errors",
            "--no-warnings",
            "--paths", "temp:\(NSTemporaryDirectory())",
        ]
        args += commonArguments(prefs: prefs, tools: tools, credential: credential)
        args += splitCommandLine(prefs.extraDiscoveryArguments)
        return args
    }

    static func download(options: DownloadOptions, prefs: Preferences, tools: ToolPaths, credential: ResolvedCredential?) -> [String] {
        let filename = resolvedFilename(options: options, prefs: prefs)
        let folder = options.saveFolder
        // yt-dlp expands templates in --output but not in --paths, so the uploader folder goes here.
        let prefix = prefs.organizeByUploader ? "%(uploader,channel|Unknown)s/" : ""

        var args = [
            options.url,
            "--ignore-config",
            "--verbose",
            "--no-warnings",
            "--progress",
            "--newline",
            "--progress-template",
            "download:\(progressPrefix);%(progress.status)s;%(progress.downloaded_bytes)s;%(progress.total_bytes)s;%(progress.total_bytes_estimate)s;%(progress.speed)s;%(progress.eta)s",
            "--progress-delta", "0.5",
            "--no-mtime",
            "--no-embed-info-json",
            "--paths", folder,
            "--paths", "temp:\(folder)",
            "--output", "\(prefix)\(filename).%(ext)s",
            "--output", "chapter:\(prefix)%(section_number)03d - \(filename) - %(section_title)s.%(ext)s",
            "--output", "thumbnail:\(prefix)\(filename).%(ext)s",
            "--print", "after_move:\(filePrefix)%(filepath)s",
            "--retries", "\(prefs.retries)",
            "--fragment-retries", "\(prefs.retries)",
        ]

        if isMusicLookup(options.url) {
            args += ["--playlist-items", "1"]
        } else if let index = options.playlistIndex {
            args += ["--playlist-items", "\(index)"]
        } else {
            args.append("--no-playlist")
        }

        args.append(prefs.overwriteExistingFiles ? "--force-overwrites" : "--no-overwrites")
        if !prefs.usePartFiles { args.append("--no-part") }
        if prefs.limitFilenameCharacters { args.append("--restrict-filenames") }
        let limit = prefs.speedLimit(for: options)
        if limit > 0 { args += ["--limit-rate", "\(limit)K"] }

        // Fast path: aria2 multi-connection for plain HTTP media, native parallel fragments for HLS/DASH.
        let fragments = prefs.turboMode ? 16 : max(1, prefs.concurrentFragments)
        // aria2 for media only in Turbo: yt-dlp's native downloader matches it on most lines and keeps live progress.
        if prefs.useAria2, prefs.turboMode, tools.aria2c != nil {
            let connections = prefs.turboMode ? 16 : max(1, min(16, prefs.aria2MaxConnections))
            args += ["--downloader", "aria2c", "--downloader", "dash,m3u8:native",
                     "--downloader-args", "aria2c:-x\(connections) -s\(connections) -k1M --file-allocation=none --uri-selector=adaptive --disk-cache=32M"]
        }
        if fragments > 1 { args += ["--concurrent-fragments", "\(fragments)"] }

        args += formatArguments(options: options, prefs: prefs)

        // Subtitles
        if !options.subtitleLanguages.isEmpty {
            args += ["--write-subs", "--sub-langs", options.subtitleLanguages.joined(separator: ",")]
            if options.includeAutoSubtitles { args.append("--write-auto-subs") }
            if prefs.subtitleFormat != .best {
                args += ["--sub-format", "\(prefs.subtitleFormat.rawValue)/best", "--convert-subs", prefs.subtitleFormat.rawValue]
            }
            if prefs.embedSubtitles, !options.fileType.isAudio { args.append("--embed-subs") }
        }

        // Metadata, thumbnails, chapters
        if prefs.embedMetadata {
            args.append("--embed-metadata")
            if let index = options.trackNumber ?? options.playlistIndex {
                args += ["--parse-metadata", "\(index):%(track_number)s"]
            }
        }
        if prefs.removeSourceData {
            for field in ["comment", "description", "purl", "synopsis"] {
                args += ["--parse-metadata", ":(?P<meta_\(field)>)"]
            }
        }
        if prefs.embedThumbnail, options.fileType.supportsEmbeddedThumbnail {
            args.append("--embed-thumbnail")
            if options.fileType.isAudio, prefs.cropAudioThumbnails {
                args += ["--postprocessor-args", "ThumbnailsConvertor+ffmpeg_o:-c:v mjpeg -qmin 1 -qscale:v 1 -vf crop=\"'if(gt(ih,iw),iw,ih)':'if(gt(iw,ih),ih,iw)'\""]
            }
        }
        if options.saveThumbnailFile { args += ["--write-thumbnail", "--convert-thumbnails", "jpg"] }
        if prefs.embedChapters { args.append("--embed-chapters") }
        if options.splitChapters { args.append("--split-chapters") }
        if options.exportDescription { args.append("--write-description") }
        if options.liveFromStart { args.append("--live-from-start") }

        if let frame = options.timeFrame {
            args += ["--download-sections", "*\(timestamp(frame.start))-\(timestamp(frame.end))", "--force-keyframes-at-cuts"]
        }

        if prefs.sponsorBlockEnabled, !prefs.sponsorBlockCategories.isEmpty, isYouTube(options.url) {
            args += ["--sponsorblock-remove", prefs.sponsorBlockCategories.map(\.rawValue).joined(separator: ",")]
        }

        if prefs.postprocessingThreads > 0 {
            args += ["--postprocessor-args", "ffmpeg:-threads \(prefs.postprocessingThreads)"]
        }

        args += commonArguments(prefs: prefs, tools: tools, credential: credential)
        for (name, value) in (options.httpHeaders ?? [:]).sorted(by: { $0.key < $1.key }) {
            args += ["--add-headers", "\(name):\(value)"]
        }
        args += splitCommandLine(prefs.extraDownloadArguments)
        args += splitCommandLine(options.extraArguments)
        return args
    }

    /// `-f`, `-S`, and conversion flags for the chosen output type.
    static func formatArguments(options: DownloadOptions, prefs: Preferences) -> [String] {
        var args: [String] = []
        var sort: [String] = []
        if let key = prefs.preferredVideoCodec.sortKey { sort.append("vcodec:\(key)") }
        if let key = prefs.preferredAudioCodec.sortKey { sort.append("acodec:\(key)") }
        if let fps = prefs.preferredFrameRate.value { sort.append("fps:\(fps)") }

        if options.fileType.isAudio {
            if let id = options.audioFormatID {
                args += ["-f", "\(id)/bestaudio/best"]
            } else {
                args += ["-f", "bestaudio/best"]
            }
            if let ext = options.fileType.fileExtension {
                args += ["--extract-audio", "--audio-format", ext, "--audio-quality", options.audioQuality.ytdlpValue]
            } else {
                args += ["--extract-audio"]
            }
        } else {
            let audio = options.audioFormatID.map { "\($0)" } ?? "bestaudio"
            // MP4/MOV should open in QuickTime and the built-in player, which can't decode VP9.
            let appleOnly = (options.fileType == .mp4 || options.fileType == .mov) && prefs.preferredVideoCodec == .any
            if let video = options.videoFormatID {
                args += ["-f", "\(video)+\(audio)/\(video)/bestvideo*+bestaudio/best"]
            } else if options.videoQuality == .worst {
                args += ["-f", "worstvideo*+worstaudio/worst"]
            } else if let height = options.videoQuality.maxHeight {
                let v = "bestvideo*[height<=\(height)]"
                args += ["-f", (appleOnly ? "\(v)[vcodec!^=vp]+\(audio)/" : "") + "\(v)+\(audio)/best[height<=\(height)]/bestvideo*+\(audio)/best"]
            } else {
                args += ["-f", (appleOnly ? "bestvideo*[vcodec!^=vp]+\(audio)/" : "") + "bestvideo*+\(audio)/best"]
            }
            // Prefer codecs the container can hold natively so remuxing (not re-encoding) suffices.
            if prefs.preferredVideoCodec == .any {
                switch options.fileType {
                case .mp4, .mov: sort += ["vcodec:h264", "acodec:m4a"]
                case .webm: sort += ["vcodec:vp9", "acodec:opus"]
                default: break
                }
            }
            if let ext = options.fileType.fileExtension {
                args += ["--merge-output-format", ext, "--remux-video", ext]
            }
        }
        if !sort.isEmpty {
            // Keep resolution as the primary key unless a codec/fps preference was set explicitly.
            let explicit = prefs.preferredVideoCodec != .any || prefs.preferredAudioCodec != .any || prefs.preferredFrameRate != .any
            args += ["-S", (explicit ? sort : ["res"] + sort).joined(separator: ",")]
        }
        return args
    }

    /// Flags shared by discovery and download: network, cookies, auth, tool locations.
    static func commonArguments(prefs: Preferences, tools: ToolPaths, credential: ResolvedCredential?) -> [String] {
        var args: [String] = []
        if let ffmpeg = tools.ffmpeg { args += ["--ffmpeg-location", ffmpeg] }
        if let deno = tools.deno { args += ["--js-runtimes", "deno:\(deno)"] }
        let proxy = prefs.proxyURL.trimmingCharacters(in: .whitespaces)
        if !proxy.isEmpty { args += ["--proxy", proxy] }
        let agent = prefs.userAgent.trimmingCharacters(in: .whitespaces)
        if !agent.isEmpty { args += ["--user-agent", agent] }
        if prefs.forceIPv4 { args.append("--force-ipv4") }
        if prefs.sleepBetweenRequests > 0 { args += ["--sleep-requests", "\(prefs.sleepBetweenRequests)"] }
        if prefs.cookieBrowser != .none {
            args += ["--cookies-from-browser", prefs.cookieBrowser.rawValue]
        } else if !prefs.cookiesFilePath.isEmpty, FileManager.default.fileExists(atPath: prefs.cookiesFilePath) {
            args += ["--cookies", prefs.cookiesFilePath]
        }
        if let credential {
            if credential.username.isEmpty {
                args += ["--video-password", credential.password]
            } else {
                args += ["--username", credential.username, "--password", credential.password]
            }
        }
        let lang = prefs.metadataLanguage.trimmingCharacters(in: .whitespaces)
        if !lang.isEmpty { args += ["--extractor-args", "youtube:lang=\(lang)"] }
        return args
    }

    /// aria2 arguments for plain files (segmented, resumable) and torrents / magnets.
    static func aria2(options: DownloadOptions, prefs: Preferences) -> [String] {
        let connections = prefs.turboMode ? 16 : max(1, min(16, prefs.directConnections))
        var args = [
            options.url,
            "--dir=\(options.saveFolder)",
            "--continue=true",
            "--summary-interval=1",
            "--console-log-level=notice",
            "--enable-color=false",
            "--file-allocation=none",
            "--auto-file-renaming=\(prefs.overwriteExistingFiles ? "false" : "true")",
            "--allow-overwrite=\(prefs.overwriteExistingFiles ? "true" : "false")",
            "--max-tries=\(max(1, prefs.retries))",
            "--retry-wait=3",
            "--connect-timeout=20",
            "--timeout=60",
            // Speed: pick the fastest source, keep connections alive, cache writes, accept compression.
            "--uri-selector=adaptive",
            "--enable-http-keep-alive=true",
            "--http-accept-gzip=true",
            "--disk-cache=\(prefs.turboMode ? 128 : 64)M",
            "--max-resume-failure-tries=5",
            "--max-file-not-found=3",
        ]
        switch options.resolvedEngine {
        case .torrent:
            args += ["--seed-time=0", "--bt-save-metadata=false", "--follow-torrent=true", "--enable-dht=true",
                     "--bt-enable-lpd=true", "--enable-peer-exchange=true", "--max-connection-per-server=\(connections)",
                     "--bt-max-peers=\(prefs.turboMode ? 200 : 80)", "--bt-request-peer-speed-limit=50M",
                     // Public trackers find peers for magnets much faster than DHT alone.
                     "--bt-tracker=" + Self.publicTrackers.joined(separator: ",")]
        default:
            args += ["--split=\(connections)", "--max-connection-per-server=\(connections)", "--min-split-size=1M"]
            let name = sanitize(options.filename.trimmingCharacters(in: .whitespacesAndNewlines))
            if !name.isEmpty { args.append("--out=\(name)") }
        }
        let limit = prefs.speedLimit(for: options)
        if limit > 0 { args.append("--max-download-limit=\(limit)K") }
        let proxy = prefs.proxyURL.trimmingCharacters(in: .whitespaces)
        if !proxy.isEmpty { args.append("--all-proxy=\(proxy)") }
        var headers = options.httpHeaders ?? [:]
        if headers["User-Agent"] == nil, !prefs.userAgent.isEmpty { headers["User-Agent"] = prefs.userAgent }
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            switch name.lowercased() {
            case "referer": args.append("--referer=\(value)")
            case "user-agent": args.append("--user-agent=\(value)")
            default: args.append("--header=\(name): \(value)")
            }
        }
        return args
    }

    static let publicTrackers = [
        "udp://tracker.opentrackr.org:1337/announce",
        "udp://open.demonii.com:1337/announce",
        "udp://open.stealth.si:80/announce",
        "udp://tracker.torrent.eu.org:451/announce",
        "udp://exodus.desync.com:6969/announce",
        "udp://tracker.openbittorrent.com:6969/announce",
        "https://tracker.tamersunion.org:443/announce",
    ]

    static func isMusicLookup(_ url: String) -> Bool {
        url.hasPrefix("https://music.youtube.com/search")
    }

    static func resolvedFilename(options: DownloadOptions, prefs: Preferences) -> String {
        var typed = options.filename.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty, let tags = options.trackTags { typed = "\(tags.artist) - \(tags.title)" }
        let explicit = sanitize(typed)
        // Literal % in a user-typed name must not be read as a template field.
        var name = explicit.isEmpty ? prefs.filenameTemplate : explicit.replacingOccurrences(of: "%", with: "%%")
        if name.trimmingCharacters(in: .whitespaces).isEmpty { name = "%(title)s" }
        if prefs.includeMediaIDInTitle, !name.contains("%(id)s") { name += " [%(id)s]" }
        return name
    }

    static func sanitize(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\")
        return name.components(separatedBy: illegal).joined(separator: "-")
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let h = Int(total) / 3600, m = (Int(total) % 3600) / 60
        let s = total - Double(h * 3600 + m * 60)
        return String(format: "%02d:%02d:%06.3f", h, m, s)
    }

    static func isYouTube(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host?.lowercased() else { return false }
        return host.hasSuffix("youtube.com") || host == "youtu.be" || host.hasSuffix("youtube-nocookie.com")
    }

    /// Shell-like splitting: whitespace separates, single/double quotes group, backslash escapes.
    static func splitCommandLine(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        var hasToken = false
        for char in line {
            if escaping { current.append(char); escaping = false; continue }
            if char == "\\", quote != "'" { escaping = true; hasToken = true; continue }
            if let q = quote {
                if char == q { quote = nil } else { current.append(char) }
                continue
            }
            if char == "\"" || char == "'" { quote = char; hasToken = true; continue }
            if char.isWhitespace {
                if hasToken { result.append(current); current = ""; hasToken = false }
                continue
            }
            current.append(char)
            hasToken = true
        }
        if hasToken { result.append(current) }
        return result
    }
}

extension MediaFileType {
    var supportsEmbeddedThumbnail: Bool {
        switch self {
        case .mp4, .mkv, .mov, .mp3, .m4a, .opus, .flac, .ogg: true
        case .webm, .wav, .originalVideo, .originalAudio: false
        }
    }
}
