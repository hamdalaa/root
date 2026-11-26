import Foundation

/// Turns Spotify / Deezer links into tracks with real tags. Each track downloads from its
/// YouTube Music match (Spotify and Deezer audio itself is DRM-protected).
enum MusicLinkResolver {
    enum Kind: String { case track, album, playlist }

    static func resolve(_ url: String) async throws -> MediaInfo {
        let finalURL = try await followShortLink(url)
        switch Platform.detect(url: finalURL) {
        case .spotify: return try await spotify(finalURL)
        case .deezer: return try await deezer(finalURL)
        default: throw DiscoveryError.failed("Unsupported music link.")
        }
    }

    /// `/intl-de/track/ID`, `/en/album/ID` → (.track, ID)
    static func parse(_ url: String) -> (Kind, String)? {
        guard let parts = URLComponents(string: url)?.path.split(separator: "/").map(String.init) else { return nil }
        for (i, part) in parts.enumerated() {
            if let kind = Kind(rawValue: part), i + 1 < parts.count { return (kind, parts[i + 1]) }
        }
        return nil
    }

    // MARK: - Spotify (public embed page; no account or API key)

    private static func spotify(_ url: String) async throws -> MediaInfo {
        guard let (kind, id) = parse(url) else { throw DiscoveryError.failed("Open a Spotify track, album or playlist link.") }
        let html = try await fetchText("https://open.spotify.com/embed/\(kind.rawValue)/\(id)")
        guard let start = html.range(of: #"<script id="__NEXT_DATA__" type="application/json">"#),
              let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex),
              let data = String(html[start.upperBound..<end.lowerBound]).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entity = (((root["props"] as? [String: Any])?["pageProps"] as? [String: Any])?["state"] as? [String: Any])
                .flatMap({ ($0["data"] as? [String: Any])?["entity"] as? [String: Any] })
        else { throw DiscoveryError.failed("Couldn't read this Spotify link. It may be private or region-locked.") }

        let name = (entity["name"] as? String) ?? (entity["title"] as? String) ?? "Spotify"
        let cover = spotifyCover(entity)

        if kind == .track {
            let artist = (entity["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.joined(separator: ", ") ?? ""
            let tags = TrackTags(title: name, artist: artist, album: nil, trackNumber: nil, coverURL: cover)
            let entry = PlaylistEntry(id: id, index: 1, url: tags.lookupURL, title: name,
                                      duration: (entity["duration"] as? Double).map { $0 / 1000 }, thumbnailURL: cover,
                                      uploader: artist, sourceURL: url, tags: tags)
            return info(title: name, uploader: artist, cover: cover, url: url, extractor: "Spotify", entries: [entry])
        }

        let collectionArtist = entity["subtitle"] as? String
        let tracks = (entity["trackList"] as? [[String: Any]]) ?? []
        let entries = tracks.enumerated().compactMap { offset, track -> PlaylistEntry? in
            guard let title = track["title"] as? String else { return nil }
            let artist = ((track["subtitle"] as? String) ?? collectionArtist ?? "").replacingOccurrences(of: "\u{a0}", with: " ")
            let trackID = (track["uri"] as? String)?.split(separator: ":").last.map(String.init) ?? "\(offset)"
            let tags = TrackTags(title: title, artist: artist, album: kind == .album ? name : nil,
                                 trackNumber: offset + 1, coverURL: cover)
            return PlaylistEntry(id: "\(offset)-\(trackID)", index: offset + 1, url: tags.lookupURL, title: title,
                                 duration: (track["duration"] as? Double).map { $0 / 1000 }, thumbnailURL: cover,
                                 uploader: artist, sourceURL: "https://open.spotify.com/track/\(trackID)", tags: tags)
        }
        guard !entries.isEmpty else { throw DiscoveryError.failed("This Spotify \(kind.rawValue) has no tracks.") }
        return info(title: name, uploader: collectionArtist, cover: cover, url: url, extractor: "Spotify", entries: entries)
    }

    private static func spotifyCover(_ entity: [String: Any]) -> String? {
        let images = ((entity["visualIdentity"] as? [String: Any])?["image"] as? [[String: Any]])
            ?? ((entity["coverArt"] as? [String: Any])?["sources"] as? [[String: Any]]) ?? []
        return images.max { ($0["maxWidth"] as? Int ?? $0["width"] as? Int ?? 0) < ($1["maxWidth"] as? Int ?? $1["width"] as? Int ?? 0) }?["url"] as? String
    }

    // MARK: - Deezer (public API)

    private static func deezer(_ url: String) async throws -> MediaInfo {
        guard let (kind, id) = parse(url) else { throw DiscoveryError.failed("Open a Deezer track, album or playlist link.") }
        let object = try await fetchJSON("https://api.deezer.com/\(kind.rawValue)/\(id)")
        if let error = object["error"] as? [String: Any] {
            throw DiscoveryError.failed("Deezer: \(error["message"] as? String ?? "not found").")
        }
        let title = (object["title"] as? String) ?? "Deezer"
        let link = (object["link"] as? String) ?? url

        if kind == .track {
            let tags = deezerTags(object, album: nil, cover: nil)
            let entry = PlaylistEntry(id: id, index: 1, url: tags.lookupURL, title: tags.title,
                                      duration: object["duration"] as? Double, thumbnailURL: tags.coverURL,
                                      uploader: tags.artist, sourceURL: link, tags: tags)
            return info(title: tags.title, uploader: tags.artist, cover: tags.coverURL, url: link, extractor: "Deezer", entries: [entry])
        }

        let collectionCover = (object["cover_xl"] as? String) ?? (object["picture_xl"] as? String)
        let tracks = ((object["tracks"] as? [String: Any])?["data"] as? [[String: Any]]) ?? []
        let entries = tracks.enumerated().map { offset, track -> PlaylistEntry in
            var tags = deezerTags(track, album: kind == .album ? title : nil, cover: collectionCover)
            if kind == .album { tags.trackNumber = offset + 1 }
            return PlaylistEntry(id: "\(offset)-\(track["id"] as? Int ?? offset)", index: offset + 1, url: tags.lookupURL,
                                 title: tags.title, duration: track["duration"] as? Double, thumbnailURL: tags.coverURL,
                                 uploader: tags.artist, sourceURL: track["link"] as? String, tags: tags)
        }
        guard !entries.isEmpty else { throw DiscoveryError.failed("This Deezer \(kind.rawValue) has no tracks.") }
        let owner = ((object["artist"] as? [String: Any])?["name"] as? String) ?? ((object["creator"] as? [String: Any])?["name"] as? String)
        return info(title: title, uploader: owner, cover: collectionCover, url: link, extractor: "Deezer", entries: entries)
    }

    private static func deezerTags(_ track: [String: Any], album: String?, cover: String?) -> TrackTags {
        let albumObject = track["album"] as? [String: Any]
        return TrackTags(title: (track["title"] as? String) ?? "Unknown",
                         artist: ((track["artist"] as? [String: Any])?["name"] as? String) ?? "",
                         album: album ?? (albumObject?["title"] as? String),
                         trackNumber: track["track_position"] as? Int,
                         coverURL: (albumObject?["cover_xl"] as? String) ?? cover)
    }

    // MARK: - Helpers

    private static func info(title: String, uploader: String?, cover: String?, url: String, extractor: String,
                             entries: [PlaylistEntry]) -> MediaInfo {
        var info = MediaInfo(meta: MediaMeta(title: title, uploader: uploader, thumbnailURL: cover, webpageURL: url, extractor: extractor))
        info.entries = entries
        return info
    }

    /// spotify.link / dzr.page.link / link.deezer.com redirect to the real page.
    private static func followShortLink(_ url: String) async throws -> String {
        guard let host = URL(string: url)?.host, host.contains(".link") || host.hasPrefix("link.") else { return url }
        var request = URLRequest(url: URL(string: url)!)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (_, response) = try await URLSession.shared.data(for: request)
        return response.url?.absoluteString ?? url
    }

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private static func fetchText(_ url: String) async throws -> String {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw DiscoveryError.failed("The music service didn't respond (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func fetchJSON(_ url: String) async throws -> [String: Any] {
        let text = try await fetchText(url)
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw DiscoveryError.failed("Unexpected response from the music service.")
        }
        return object
    }
}

/// Writes TrackTags (and the album cover) into a finished audio file with ffmpeg, in place.
enum MusicTagger {
    static func apply(_ tags: TrackTags, to path: String, ffmpeg: String) async {
        let source = URL(fileURLWithPath: path)
        let ext = source.pathExtension.lowercased()
        let temp = source.deletingLastPathComponent().appendingPathComponent(".tagging-\(UUID().uuidString).\(ext)")

        var coverFile: URL?
        if ["mp3", "m4a"].contains(ext), let cover = tags.coverURL, let coverURL = URL(string: cover),
           let (data, _) = try? await URLSession.shared.data(from: coverURL) {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("cover-\(UUID().uuidString).jpg")
            if (try? data.write(to: file)) != nil { coverFile = file }
        }
        defer { if let coverFile { try? FileManager.default.removeItem(at: coverFile) } }

        var args = ["-hide_banner", "-nostdin", "-y", "-i", path]
        if let coverFile {
            args += ["-i", coverFile.path, "-map", "0:a", "-map", "1:0", "-c", "copy", "-disposition:v:0", "attached_pic"]
        } else {
            args += ["-map", "0", "-c", "copy"]
        }
        args += ["-metadata", "title=\(tags.title)", "-metadata", "artist=\(tags.artist)"]
        if let album = tags.album { args += ["-metadata", "album=\(album)", "-metadata", "album_artist=\(tags.artist)"] }
        if let track = tags.trackNumber { args += ["-metadata", "track=\(track)"] }
        if ext == "mp3" { args += ["-id3v2_version", "3"] }
        args.append(temp.path)

        let result = try? await ProcessRunner.capture(executable: ffmpeg, arguments: args)
        if result?.status == 0, FileManager.default.fileExists(atPath: temp.path) {
            _ = try? FileManager.default.replaceItemAt(source, withItemAt: temp)
        } else {
            try? FileManager.default.removeItem(at: temp)
        }
    }
}
