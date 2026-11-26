import Foundation
import Testing
@testable import Parabolic

@Suite struct MusicLinkTests {
    @Test func parsesLinkKinds() {
        #expect(MusicLinkResolver.parse("https://open.spotify.com/intl-de/track/4cOdK2wGLETKBW3PvgPWqT?si=x")?.1 == "4cOdK2wGLETKBW3PvgPWqT")
        #expect(MusicLinkResolver.parse("https://www.deezer.com/en/album/302127")?.0 == .album)
        #expect(Platform.detect(url: "https://open.spotify.com/track/x") == .spotify)
        #expect(Platform.detect(url: "https://www.deezer.com/track/1") == .deezer)
    }

    @Test func spotifyAndDeezerDefaultToAudio() {
        #expect(Preferences().preset(for: .spotify).fileType.isAudio)
        #expect(Preferences().preset(for: .deezer).fileType.isAudio)
    }

    @Test func lookupDownloadsTopResultNamedFromTags() {
        let tags = TrackTags(title: "Song", artist: "Artist")
        var options = DownloadOptions(url: tags.lookupURL, saveFolder: "/tmp")
        options.trackTags = tags
        let args = ArgumentBuilder.download(options: options, prefs: Preferences(), tools: ToolPaths(), credential: nil)
        #expect(args.containsSequence(["--playlist-items", "1"]))
        #expect(args.containsSequence(["--output", "Artist - Song.%(ext)s"]))
    }

    /// Live: PB_LIVE=1 ./scripts/test.sh --filter MusicLinkTests
    @Test func liveResolve() async throws {
        guard ProcessInfo.processInfo.environment["PB_LIVE"] != nil else { return }
        let track = try await MusicLinkResolver.resolve("https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT")
        #expect(track.entries.first?.tags?.artist == "Rick Astley")
        let playlist = try await MusicLinkResolver.resolve("https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M")
        #expect(playlist.entries.count > 10)
        let album = try await MusicLinkResolver.resolve("https://www.deezer.com/album/302127")
        #expect(album.entries.count > 5)
        #expect(album.entries.first?.tags?.album == album.meta.title)
        print("SPOTIFY", track.entries[0].tags!, playlist.entries.count, "DEEZER", album.meta.title, album.entries.count, album.entries[0].tags!)
    }
}

@Suite struct EngineTests {
    @Test(arguments: [
        ("magnet:?xt=urn:btih:abc&dn=Ubuntu", DownloadEngine.torrent),
        ("https://x.org/a.torrent", .torrent),
        ("https://x.org/file.zip?x=1", .direct),
        ("https://cdn.example/clip.mp4", .direct),
        ("https://www.youtube.com/watch?v=1", .media),
        ("https://example.com/page", .media),
    ])
    func routes(url: String, engine: DownloadEngine) { #expect(EngineRouter.engine(for: url) == engine) }

    @Test func magnetName() { #expect(EngineRouter.magnetName("magnet:?xt=urn:btih:abc&dn=Ubuntu%2024") == "Ubuntu 24") }

    @Test func contentDisposition() {
        #expect(DirectProbe.filename(from: #"attachment; filename="a b.zip""#) == "a b.zip")
        #expect(DirectProbe.filename(from: "attachment; filename*=UTF-8''%E2%9C%93.pdf") == "✓.pdf")
    }

    @Test func aria2ArgsCarryHeadersAndName() {
        var options = DownloadOptions(url: "https://x.org/f.zip", saveFolder: "/tmp")
        options.engine = .direct
        options.filename = "f.zip"
        options.httpHeaders = ["Cookie": "a=1", "Referer": "https://x.org"]
        let args = ArgumentBuilder.aria2(options: options, prefs: Preferences())
        #expect(args.contains("--out=f.zip"))
        #expect(args.contains("--header=Cookie: a=1"))
        #expect(args.contains("--referer=https://x.org"))
        #expect(args.contains("--split=16"))
    }

    @Test func parsesAriaCompletion() {
        #expect(ProgressParser.parse("10/16 15:31:43 [NOTICE] Download complete: /tmp/a.zip") == .finalFile("/tmp/a.zip"))
    }

    @Test func transientErrors() {
        #expect(DownloadManager.isTransient("HTTP Error 403: Forbidden"))
        #expect(!DownloadManager.isTransient("Unsupported URL: x"))
    }
}

@Suite struct AuditFixTests {
    @Test func uploaderFolderGoesInOutputNotPaths() {
        var prefs = Preferences()
        prefs.organizeByUploader = true
        let args = ArgumentBuilder.download(options: DownloadOptions(url: "https://x.org/v", saveFolder: "/tmp/dl"),
                                            prefs: prefs, tools: ToolPaths(), credential: nil)
        #expect(args.containsSequence(["--paths", "/tmp/dl"]))
        #expect(args.contains { $0.hasPrefix("%(uploader,channel|Unknown)s/") })
    }

    @Test func watchLinksStaySingle() {
        #expect(DownloadManager.isWatchLink("https://www.youtube.com/watch?v=X&list=RD1"))
        #expect(!DownloadManager.isWatchLink("https://www.youtube.com/playlist?list=PL1"))
    }

    @Test func lossyDecodingKeepsGoodRecordsAndBacksUp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("history.json")
        let good = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","url":"https://a","title":"A","fileType":"mp4","date":"2026-10-16T10:00:00Z"}"#
        try Data("[\(good), {\"broken\": true}]".utf8).write(to: file)
        let entries = LossyDecoding.decodeArray(HistoryEntry.self, from: file, decoder: .iso)
        #expect(entries.map(\.title) == ["A"])
        #expect(FileManager.default.fileExists(atPath: file.path + ".bak"))
    }
}

@Suite struct BandwidthTests {
    func date(weekday: Int, hour: Int) -> Date {
        // 2026-10-12 is a Monday.
        var parts = DateComponents(year: 2026, month: 10, day: 11 + weekday, hour: hour)
        parts.timeZone = .current
        return Calendar.current.date(from: parts)!
    }

    @Test func windowAppliesOnlyInHours() {
        var prefs = Preferences()
        prefs.bandwidthScheduleEnabled = true
        prefs.bandwidthScheduleLimitKBps = 300
        #expect(prefs.effectiveSpeedLimitKBps(at: date(weekday: 1, hour: 10)) == 300)
        #expect(prefs.effectiveSpeedLimitKBps(at: date(weekday: 1, hour: 20)) == 0)
        #expect(prefs.effectiveSpeedLimitKBps(at: date(weekday: 6, hour: 10)) == 0) // Saturday, weekdays only
    }

    @Test func overnightWindowWraps() {
        var prefs = Preferences()
        prefs.bandwidthScheduleEnabled = true
        prefs.bandwidthScheduleWeekdaysOnly = false
        prefs.bandwidthScheduleStartHour = 22
        prefs.bandwidthScheduleEndHour = 6
        #expect(prefs.isInBandwidthWindow(at: date(weekday: 2, hour: 23)))
        #expect(prefs.isInBandwidthWindow(at: date(weekday: 2, hour: 3)))
        #expect(!prefs.isInBandwidthWindow(at: date(weekday: 2, hour: 12)))
    }

    @Test func perDownloadLimitWins() {
        var options = DownloadOptions(url: "https://x.org/f.zip", saveFolder: "/tmp")
        options.engine = .direct
        options.speedLimitKBps = 100
        var prefs = Preferences()
        prefs.speedLimitKBps = 5000
        #expect(ArgumentBuilder.aria2(options: options, prefs: prefs).contains("--max-download-limit=100K"))
        options.speedLimitKBps = 0
        #expect(!ArgumentBuilder.aria2(options: options, prefs: prefs).contains { $0.hasPrefix("--max-download-limit") })
    }
}

@Suite struct FastFeatureTests {
    @Test func categories() {
        #expect(FileCategory.of(filename: "a.dmg", engine: .direct, fileType: .mp4) == .apps)
        #expect(FileCategory.of(filename: "a.zip", engine: .direct, fileType: .mp4) == .archives)
        #expect(FileCategory.of(filename: "x", engine: .torrent, fileType: .mp4) == .torrents)
        #expect(FileCategory.of(filename: "song", engine: .media, fileType: .mp3) == .music)
    }

    @Test func checksumStreamsAndMatches() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("abc".utf8).write(to: file)
        let hash = await Checksum.sha256(of: file.path)
        #expect(hash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(Checksum.matches(hash!, expected: "BA7816BF 8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"))
    }

    @Test func torrentsGetTrackersAndTurboConnections() {
        var options = DownloadOptions(url: "magnet:?xt=urn:btih:abc", saveFolder: "/tmp")
        options.engine = .torrent
        var prefs = Preferences()
        prefs.turboMode = true
        let args = ArgumentBuilder.aria2(options: options, prefs: prefs)
        #expect(args.contains { $0.hasPrefix("--bt-tracker=udp://tracker.opentrackr.org") })
        #expect(args.contains("--max-connection-per-server=16"))
        #expect(args.contains("--disk-cache=128M"))
    }

    @Test func mediaUsesAria2OnlyInTurbo() {
        let tools = ToolPaths(ytdlp: "/x", ffmpeg: nil, deno: nil, aria2c: "/a")
        let options = DownloadOptions(url: "https://x.org/v", saveFolder: "/tmp")
        var prefs = Preferences()
        #expect(!ArgumentBuilder.download(options: options, prefs: prefs, tools: tools, credential: nil).contains("aria2c"))
        prefs.turboMode = true
        #expect(ArgumentBuilder.download(options: options, prefs: prefs, tools: tools, credential: nil).contains("aria2c"))
    }

    @Test func extractableArchives() {
        #expect(ArchiveExtractor.canExtract("/x/a.tar.gz"))
        #expect(!ArchiveExtractor.canExtract("/x/a.dmg"))
    }
}

@Suite struct SpeedFixTests {
    @Test func abortedMirrorsRetry() {
        #expect(DownloadManager.isTransient("Download aborted. URI=https://mirror/x.dmg"))
    }
}
