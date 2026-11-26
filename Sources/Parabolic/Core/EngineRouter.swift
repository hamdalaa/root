import Foundation

/// Decides which engine handles a link: torrents and plain files go to aria2, everything else to yt-dlp.
enum EngineRouter {
    /// File extensions that are downloaded as-is (not media pages).
    static let directExtensions: Set<String> = [
        "zip", "rar", "7z", "dmg", "pkg", "iso", "img", "exe", "msi", "apk", "ipa", "xapk", "deb", "rpm",
        "appimage", "tar", "gz", "tgz", "bz2", "xz", "zst", "pdf", "epub", "mobi", "doc", "docx", "xls", "xlsx",
        "ppt", "pptx", "csv", "txt", "bin", "jar", "ttf", "otf", "psd", "ai", "sketch", "blend", "glb", "safetensors",
        "gguf", "ckpt", "pt",
    ]
    /// Media files linked directly (not a page); aria2 is faster than yt-dlp's generic extractor for these.
    static let directMediaExtensions: Set<String> = ["mp4", "mkv", "mov", "avi", "webm", "mp3", "flac", "wav", "m4a", "ogg", "aac"]

    static func engine(for url: String) -> DownloadEngine {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("magnet:") { return .torrent }
        if trimmed.hasPrefix("/"), trimmed.lowercased().hasSuffix(".torrent") { return .torrent }
        guard let components = URLComponents(string: trimmed) else { return .media }
        let ext = (components.path as NSString).pathExtension.lowercased()
        if ext == "torrent" { return .torrent }
        if directExtensions.contains(ext) { return .direct }
        // A raw media file on an unknown host is a file; on a known platform it's a page for yt-dlp.
        if directMediaExtensions.contains(ext), Platform.detect(url: trimmed) == .other { return .direct }
        return .media
    }

    /// Display name for a magnet link (`dn=`), else the info-hash.
    static func magnetName(_ url: String) -> String {
        let items = URLComponents(string: url)?.queryItems ?? []
        if let name = items.first(where: { $0.name == "dn" })?.value, !name.isEmpty {
            return name.replacingOccurrences(of: "+", with: " ")
        }
        if let xt = items.first(where: { $0.name == "xt" })?.value { return String(xt.split(separator: ":").last ?? "Torrent") }
        return "Torrent"
    }
}

/// HEAD (or 1-byte ranged GET) to learn a file's name, size and whether it can resume.
enum DirectProbe {
    static func probe(_ url: String, headers: [String: String] = [:]) async throws -> MediaInfo {
        guard let target = URL(string: url) else { throw DiscoveryError.invalidURL }
        var request = URLRequest(url: target, timeoutInterval: 20)
        request.httpMethod = "HEAD"
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        var (_, response) = try await URLSession.shared.data(for: request)
        var http = response as? HTTPURLResponse
        if http == nil || !(200..<400).contains(http!.statusCode) {
            // Some servers reject HEAD; ask for the first byte instead.
            request.httpMethod = "GET"
            request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            (_, response) = try await URLSession.shared.data(for: request)
            http = response as? HTTPURLResponse
        }
        guard let http, (200..<400).contains(http.statusCode) else {
            throw DiscoveryError.failed("The server answered HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        let finalURL = http.url ?? target
        let filename = filename(from: http.value(forHTTPHeaderField: "Content-Disposition"))
            ?? finalURL.lastPathComponent.removingPercentEncoding.flatMap { $0.isEmpty || $0 == "/" ? nil : $0 }
            ?? (finalURL.host ?? "download")
        var size = http.expectedContentLength > 0 ? http.expectedContentLength : nil
        if let range = http.value(forHTTPHeaderField: "Content-Range"), let total = range.split(separator: "/").last.flatMap({ Int64($0) }) {
            size = total
        }
        let resumable = http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes" || http.statusCode == 206
        let file = DirectFileInfo(filename: ArgumentBuilder.sanitize(filename), size: size,
                                  contentType: http.value(forHTTPHeaderField: "Content-Type"), resumable: resumable)
        var info = MediaInfo(meta: MediaMeta(title: file.filename, uploader: finalURL.host, webpageURL: url, extractor: "File"))
        info.directFile = file
        info.engine = .direct
        return info
    }

    static func torrent(_ url: String) -> MediaInfo {
        let name = url.lowercased().hasPrefix("magnet:") ? EngineRouter.magnetName(url)
            : ((URL(string: url)?.lastPathComponent as NSString?)?.deletingPathExtension ?? "Torrent")
        var info = MediaInfo(meta: MediaMeta(title: name, webpageURL: url, extractor: "Torrent"))
        info.engine = .torrent
        return info
    }

    /// `attachment; filename="a b.zip"; filename*=UTF-8''a%20b.zip`
    static func filename(from disposition: String?) -> String? {
        guard let disposition else { return nil }
        for part in disposition.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if part.lowercased().hasPrefix("filename*="), let value = part.split(separator: "'", maxSplits: 2).last {
                return String(value).removingPercentEncoding
            }
        }
        for part in disposition.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) })
        where part.lowercased().hasPrefix("filename=") {
            return String(part.dropFirst(9)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
        return nil
    }
}
